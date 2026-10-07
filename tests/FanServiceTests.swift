import Foundation

private final class TestSMC: FanSMC {
    var values: [String: Double] = ["FNum": 1, "Ftst": 0, "F0Md": 0,
                                   "F0Mn": 2000, "F0Mx": 6000, "F0Ac": 2000, "F0Tg": 2000]
    func read(_ key: String) throws -> Double {
        guard let value = values[key] else { throw FanError(message: "Missing key") }
        return value
    }
    func write(_ key: String, _ value: Double) throws { values[key] = value }
}

@main struct FanServiceTests {
    static func main() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("menustat-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let service = try FanService(hardware: FanHardware(smc: TestSMC()), requirement: fanCodeRequirement(),
                                     ownershipURL: marker, leaseDuration: 0.2)
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()

        func connect() throws -> NSXPCConnection {
            let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
            connection.setCodeSigningRequirement(try fanCodeRequirement())
            connection.remoteObjectInterface = NSXPCInterface(with: FanServiceProtocol.self)
            connection.resume()
            return connection
        }

        func request(_ connection: NSXPCConnection, _ mode: String?) -> (FanStatus?, String?) {
            let lock = NSLock()
            var result: (FanStatus?, String?)?
            func complete(_ json: String?, _ error: String?) {
                lock.lock()
                result = (json.flatMap { try? JSONDecoder().decode(FanStatus.self, from: Data($0.utf8)) }, error)
                lock.unlock()
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { complete(nil, $0.localizedDescription) } as! FanServiceProtocol
            if let mode = mode { proxy.setMode(mode, reply: complete) } else { proxy.status(reply: complete) }
            let deadline = Date(timeIntervalSinceNow: 5)
            while Date() < deadline {
                lock.lock(); let value = result; lock.unlock()
                if let value = value { return value }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            }
            fatalError("XPC request timed out")
        }

        let connection = try connect()
        precondition(request(connection, "max").0?.mode == .max)
        precondition(FileManager.default.fileExists(atPath: marker.path))
        let unknown = request(connection, "arbitrary-key-write")
        precondition(unknown.0 == nil && unknown.1 != nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.5))
        precondition(request(connection, nil).0?.mode == .auto, "Expired app lease must restore Auto")
        precondition(!FileManager.default.fileExists(atPath: marker.path))
        precondition(request(connection, "medium").0?.fans.first?.target == 4000)
        connection.invalidate()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        let second = try connect()
        precondition(request(second, nil).0?.mode == .auto, "Disconnect must restore Auto")
        second.invalidate()
        listener.invalidate()

        // A valid XPC message from code that fails the peer requirement must
        // never reach the exported service, even for a status request.
        let rejectedService = try FanService(hardware: FanHardware(smc: TestSMC()),
                                             requirement: "identifier \"not.menustat\"", ownershipURL: marker)
        let rejectedListener = NSXPCListener.anonymous()
        rejectedListener.delegate = rejectedService
        rejectedListener.resume()
        let rejected = NSXPCConnection(listenerEndpoint: rejectedListener.endpoint)
        rejected.remoteObjectInterface = NSXPCInterface(with: FanServiceProtocol.self)
        rejected.resume()
        let denied = request(rejected, nil)
        precondition(denied.0 == nil && denied.1 != nil, "Untrusted clients must be rejected")
        rejected.invalidate()
        rejectedListener.invalidate()
        print("PASS: authenticated XPC, rejected peer, preset-only commands, lease expiry, disconnect reset")
    }
}
