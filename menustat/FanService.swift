import Foundation
import Security

let fanServiceName = "com.digitalsophistry.menustat.fans"

@objc protocol FanServiceProtocol {
    func setMode(_ mode: String, reply: @escaping (String?, String?) -> Void)
    func status(reply: @escaping (String?, String?) -> Void)
}

// The app and its launchd helper run the same signed executable, through
// separate entry points. Authenticate both ends with that executable's exact
// designated requirement, including the CDHash for local ad-hoc builds.
func fanCodeRequirement() throws -> String {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var requirement: SecRequirement?
    var text: CFString?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code = code,
          SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode = staticCode,
          SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
          let requirement = requirement,
          SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text = text else {
        throw FanError(message: "Cannot verify the fan helper's code signature. Rebuild and sign menustat.")
    }
    return text as String
}

final class FanServiceSession: NSObject, FanServiceProtocol {
    let id = UUID()
    private let service: FanService

    init(service: FanService) { self.service = service }

    func setMode(_ mode: String, reply: @escaping (String?, String?) -> Void) {
        service.perform(owner: id, selected: mode, reply: reply)
    }

    func status(reply: @escaping (String?, String?) -> Void) {
        service.perform(owner: id, selected: nil, reply: reply)
    }
}

final class FanService: NSObject, NSXPCListenerDelegate {
    private let hardware: FanHardware
    private let requirement: String
    private let queue = DispatchQueue(label: "menustat.fan-helper", qos: .utility)
    private let watchdog: DispatchSourceTimer
    private var owner: UUID?
    private var lastContact = 0.0
    private let ownershipURL: URL
    private let leaseDuration: TimeInterval

    init(hardware: FanHardware, requirement: String,
         ownershipURL: URL = URL(fileURLWithPath: "/var/run/com.digitalsophistry.menustat.fans.owned"),
         leaseDuration: TimeInterval = 10) {
        self.hardware = hardware
        self.requirement = requirement
        self.ownershipURL = ownershipURL
        self.leaseDuration = leaseDuration
        watchdog = DispatchSource.makeTimerSource(queue: queue)
        super.init()
        watchdog.schedule(deadline: .distantFuture)
        watchdog.setEventHandler { [weak self] in self?.checkLease() }
        watchdog.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let session = FanServiceSession(service: self)
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: FanServiceProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { [weak self] in
            guard let self = self else { return }
            self.queue.async {
                if self.owner == session.id { self.returnToAuto() }
            }
        }
        connection.resume()
        return true
    }

    func perform(owner client: UUID, selected: String?, reply: @escaping (String?, String?) -> Void) {
        queue.async {
            do {
                if let selected = selected {
                    guard let mode = FanMode(rawValue: selected) else {
                        throw FanError(message: "Unknown fan preset.")
                    }
                    if let owner = self.owner, owner != client {
                        throw FanError(message: "Fan control is in use by another menustat instance.")
                    }
                    if mode != .auto, ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                        throw FanError(message: "This Mac is under thermal pressure. Leave fan control on Auto.")
                    }
                    if mode != .auto { try Data().write(to: self.ownershipURL, options: .atomic) }
                    try self.hardware.set(mode)
                    if mode == .auto { try? FileManager.default.removeItem(at: self.ownershipURL) }
                    self.owner = mode == .auto ? nil : client
                    self.watchdog.schedule(deadline: mode == .auto ? .distantFuture : .now() + 1,
                                           repeating: 1, leeway: .milliseconds(200))
                }
                if self.owner == client { self.lastContact = ProcessInfo.processInfo.systemUptime }
                let data = try JSONEncoder().encode(self.hardware.status())
                reply(String(decoding: data, as: UTF8.self), nil)
            } catch {
                // A partial write must retain a reset watchdog even when
                // rollback itself fails. Keep retrying until Auto is verified.
                if self.hardware.needsRestore, self.hardware.mode == nil {
                    self.owner = nil
                    self.watchdog.schedule(deadline: .now() + 1, repeating: 1)
                } else if !self.hardware.needsRestore {
                    self.owner = nil
                    try? FileManager.default.removeItem(at: self.ownershipURL)
                    self.watchdog.schedule(deadline: .distantFuture)
                }
                reply(nil, error.localizedDescription)
            }
        }
    }

    private func checkLease() {
        guard hardware.needsRestore else {
            watchdog.schedule(deadline: .distantFuture)
            return
        }
        let expired = ProcessInfo.processInfo.systemUptime - lastContact > leaseDuration
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        let fans = try? hardware.readings()
        let reclaimed = fans == nil || fans!.contains { !$0.manual }
        if owner == nil || expired || hot || reclaimed { returnToAuto() }
    }

    private func returnToAuto() {
        owner = nil
        do {
            try hardware.restore()
            try? FileManager.default.removeItem(at: ownershipURL)
            watchdog.schedule(deadline: .distantFuture)
        } catch {
            NSLog("menustat: automatic fan reset failed: %@", error.localizedDescription)
            watchdog.schedule(deadline: .now() + 1, repeating: 1)
        }
    }

    static func run() -> Never {
        guard geteuid() == 0 else {
            fputs("Fan helper must be started by macOS Service Management.\n", stderr)
            exit(1)
        }
        do {
            let service = try FanService(hardware: FanHardware(smc: SMCConnection()), requirement: fanCodeRequirement())
            // A launchd restart after a helper crash must restore our previous
            // manual session, while leaving other fan apps alone on first use.
            if FileManager.default.fileExists(atPath: service.ownershipURL.path) {
                service.returnToAuto()
            }
            let listener = NSXPCListener(machServiceName: fanServiceName)
            listener.delegate = service
            // launchd sends SIGTERM when the helper is unregistered or updated.
            signal(SIGTERM, SIG_IGN)
            let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: service.queue)
            termination.setEventHandler {
                if service.hardware.needsRestore { service.returnToAuto() }
                exit(0)
            }
            termination.resume()
            listener.resume()
            withExtendedLifetime((service, listener, termination)) { dispatchMain() }
        } catch {
            NSLog("menustat fan helper: %@", error.localizedDescription)
            exit(1)
        }
    }
}
