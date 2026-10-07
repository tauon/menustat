import Cocoa
import ServiceManagement

// UI state belongs to the main queue. Hardware discovery and service
// registration run off the main queue, so opening the menu stays responsive.
final class FanController {
    private let queue = DispatchQueue(label: "menustat.fans", qos: .utility)
    private let service = SMAppService.daemon(plistName: "com.digitalsophistry.menustat.fans.plist")
    private var connection: NSXPCConnection?
    private var heartbeat: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var items: [NSMenuItem] = []
    private(set) var menuItem = NSMenuItem(title: "Fan Control", action: nil, keyEquivalent: "")
    private var status: FanStatus?
    private var changing = false
    private var connected = false
    private var requestNumber = 0

    init() {
        let menu = NSMenu(title: "Fan Control")
        menu.autoenablesItems = false
        for (index, mode) in FanMode.allCases.enumerated() {
            let item = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.isEnabled = false
            menu.addItem(item)
            items.append(item)
        }
        menuItem.submenu = menu
    }

    func start() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.restore { }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
    }

    func refresh() {
        guard !changing else { return }
        if connected { send(nil) { _ in }; return }
        queue.async {
            let result = Result { try FanHardware(smc: SMCConnection()).status() }
            DispatchQueue.main.async {
                guard !self.connected, !self.changing else { return }
                switch result {
                case .success(let status): self.status = status; self.render()
                case .failure(let error):
                    self.status = nil
                    self.menuItem.title = "Fan Control: Unavailable"
                    self.menuItem.toolTip = error.localizedDescription
                    self.items.forEach { $0.isEnabled = false; $0.state = .off }
                }
            }
        }
    }

    private func render() {
        let title = changing ? "Fan Control: Applying…" : "Fan Control: \(status?.mode?.title ?? "External")"
        if menuItem.title != title { menuItem.title = title }
        menuItem.toolTip = status?.fans.map { fan in
            "Fan \(fan.index + 1): \(Int(fan.actual.rounded())) RPM (\(Int(fan.minimum))–\(Int(fan.maximum)))"
        }.joined(separator: "\n")
        for (index, item) in items.enumerated() {
            let mode = FanMode.allCases[index]
            let state: NSControl.StateValue = status?.mode == mode ? .on : .off
            if item.state != state { item.state = state }
            let enabled = !changing && status != nil
            if item.isEnabled != enabled { item.isEnabled = enabled }
            if mode == .medium, let fans = status?.fans {
                item.toolTip = fans.map { "Fan \($0.index + 1): \(Int((($0.minimum + $0.maximum) / 2).rounded())) RPM" }.joined(separator: "\n")
            }
        }
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        let mode = FanMode.allCases[sender.tag]
        guard !changing else { return }
        if mode == .auto, status?.mode == .auto, !connected { return }
        changing = true
        render()
        queue.async {
            do {
                if self.service.status == .notRegistered || self.service.status == .notFound { try self.service.register() }
                guard self.service.status == .enabled else {
                    throw FanError(message: "Allow menustat in System Settings → General → Login Items & Extensions, then choose the fan preset again.")
                }
                let requirement = try fanCodeRequirement()
                DispatchQueue.main.async {
                    self.connect(requirement: requirement)
                    self.send(mode) { error in
                        self.changing = false
                        self.render()
                        if let error = error {
                            // A failed write can successfully roll back to Auto.
                            // Refresh the checkmark before displaying the error.
                            self.send(nil) { _ in self.show(error, approval: false) }
                        }
                    }
                }
            } catch {
                let approval = self.service.status == .requiresApproval
                DispatchQueue.main.async {
                    self.changing = false
                    self.render()
                    let message = approval ? "Allow menustat in System Settings → General → Login Items & Extensions, then choose the fan preset again." : error.localizedDescription
                    self.show(message, approval: approval)
                }
            }
        }
    }

    private func connect(requirement: String) {
        guard connection == nil else { return }
        let connection = NSXPCConnection(machServiceName: fanServiceName, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: FanServiceProtocol.self)
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.connection = nil
                self.connected = false
                self.heartbeat?.cancel()
                self.heartbeat = nil
                self.status = nil
                self.menuItem.title = "Fan Control: Disconnected"
                self.items.forEach { $0.state = .off }
                self.refresh()
            }
        }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        connection.resume()
        self.connection = connection
        connected = true
    }

    private func send(_ mode: FanMode?, completion: @escaping (String?) -> Void) {
        guard let connection = connection else { completion("Fan helper is not connected."); return }
        requestNumber += 1
        let request = requestNumber
        var finished = false
        let finish: (String?, String?) -> Void = { json, error in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                if let json = json, let status = try? JSONDecoder().decode(FanStatus.self, from: Data(json.utf8)) {
                    self.status = status
                    self.render()
                    self.updateHeartbeat()
                }
                completion(error)
            }
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { finish(nil, $0.localizedDescription) } as? FanServiceProtocol
        guard let proxy = proxy else { finish(nil, "Cannot connect to the fan helper."); return }
        if let mode = mode { proxy.setMode(mode.rawValue, reply: finish) }
        else { proxy.status(reply: finish) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            guard !finished else { return }
            finish(nil, "The fan helper did not respond. Fan control will return to Auto when its connection expires.")
            if request == self.requestNumber { connection.invalidate() }
        }
    }

    private func updateHeartbeat() {
        let manual = status?.mode == .medium || status?.mode == .max
        guard manual else {
            heartbeat?.cancel()
            heartbeat = nil
            return
        }
        guard heartbeat == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3, repeating: 3, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.changing else { return }
            self.send(nil) { _ in }
        }
        timer.resume()
        heartbeat = timer
    }

    func restore(completion: @escaping () -> Void) {
        heartbeat?.cancel()
        heartbeat = nil
        guard connected, changing || status?.mode == .medium || status?.mode == .max else { completion(); return }
        send(.auto) { _ in completion() }
    }

    private func show(_ message: String, approval: Bool) {
        let alert = NSAlert()
        alert.messageText = approval ? "Enable Fan Control" : "Fan Control"
        alert.informativeText = message
        alert.addButton(withTitle: approval ? "Open System Settings" : "OK")
        if approval { alert.addButton(withTitle: "Cancel") }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, approval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    static func serviceCommand(register: Bool) -> Int32 {
        let service = SMAppService.daemon(plistName: "com.digitalsophistry.menustat.fans.plist")
        do {
            if register, service.status == .enabled {
                let finished = DispatchSemaphore(value: 0)
                var failure: Error?
                service.unregister { error in failure = error; finished.signal() }
                guard finished.wait(timeout: .now() + 10) == .success else {
                    throw FanError(message: "Timed out restarting the updated fan service.")
                }
                if let failure = failure { throw failure }
            }
            if register, service.status == .notRegistered || service.status == .notFound {
                // Background Task Management can lag launchd's unregister
                // completion. Wait briefly for it to accept the replacement.
                for attempt in 0 ..< 20 {
                    do { try service.register(); break }
                    catch {
                        let failure = error as NSError
                        guard attempt < 19, service.status != .requiresApproval,
                              failure.domain == SMAppServiceErrorDomain, failure.code == 1 else { throw error }
                        Thread.sleep(forTimeInterval: 0.25)
                    }
                }
            }
        } catch {
            if service.status != .requiresApproval { fputs("\(error.localizedDescription)\n", stderr); return 1 }
        }
        switch service.status {
        case .enabled: print("Fan service enabled"); return 0
        case .requiresApproval: print("Fan service needs administrator approval in System Settings > General > Login Items & Extensions"); return 2
        case .notRegistered: print("Fan service not registered"); return 0
        case .notFound: print("Fan service configuration not found"); return 1
        @unknown default: print("Unknown fan service status"); return 1
        }
    }
}
