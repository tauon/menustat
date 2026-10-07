import Foundation

// Explicit developer diagnostic: exercise the installed, authenticated helper
// and actual RPM feedback, always returning to Auto before disconnecting.
enum FanControlProbe {
    static func run() -> Int32 {
        do {
            let baseline = try FanHardware(smc: SMCConnection()).status()
            guard baseline.mode == .auto else {
                throw FanError(message: "Start the fan test from Auto with other fan controllers closed.")
            }
            let connection = NSXPCConnection(machServiceName: fanServiceName, options: .privileged)
            connection.setCodeSigningRequirement(try fanCodeRequirement())
            connection.remoteObjectInterface = NSXPCInterface(with: FanServiceProtocol.self)
            connection.resume()
            func request(_ mode: FanMode?) throws -> FanStatus {
                let done = DispatchSemaphore(value: 0)
                let lock = NSLock()
                var result: Result<FanStatus, Error>?
                let finish: (String?, String?) -> Void = { json, error in
                    lock.lock()
                    defer { lock.unlock() }
                    guard result == nil else { return }
                    result = Result {
                        guard let json = json, error == nil else {
                            throw FanError(message: error ?? "Fan helper returned no status.")
                        }
                        return try JSONDecoder().decode(FanStatus.self, from: Data(json.utf8))
                    }
                    done.signal()
                }
                let proxy = connection.remoteObjectProxyWithErrorHandler { finish(nil, $0.localizedDescription) } as! FanServiceProtocol
                if let mode = mode { proxy.setMode(mode.rawValue, reply: finish) }
                else { proxy.status(reply: finish) }
                guard done.wait(timeout: .now() + 25) == .success else { throw FanError(message: "Fan test timed out.") }
                lock.lock(); defer { lock.unlock() }
                return try result!.get()
            }
            defer {
                do { _ = try request(.auto) } catch { fputs("Auto reset: \(error.localizedDescription)\n", stderr) }
                connection.invalidate()
            }
            for mode in [FanMode.medium, .max] {
                var status = try request(mode)
                var reached = false
                for _ in 0 ..< 30 {
                    guard status.mode == mode else { throw FanError(message: "macOS reclaimed fan control during the test.") }
                    if status.fans.allSatisfy({ abs($0.actual - $0.target) <= max(100, $0.target * 0.03) }) {
                        reached = true
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.5)
                    status = try request(nil) // Renews the helper lease.
                }
                let json = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
                print("\(mode.title): \(json)")
                fflush(stdout)
                guard reached else { throw FanError(message: "Measured RPM did not reach the \(mode.title) target.") }
            }
            let automatic = try request(.auto)
            guard automatic.mode == .auto, automatic.fans.allSatisfy({ !$0.manual }) else {
                throw FanError(message: "Auto reset was not confirmed.")
            }
            print("PASS: Medium and Max reached their measured RPMs; Auto restored.")
            return 0
        } catch { fputs("\(error.localizedDescription)\n", stderr); return 1 }
    }
}
