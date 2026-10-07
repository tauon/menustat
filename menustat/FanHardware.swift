import Foundation
import IOKit

enum FanMode: String, CaseIterable, Codable {
    case auto, medium, max
    var title: String { rawValue.capitalized }
}

struct FanReading: Codable {
    let index: Int
    let minimum: Double
    let maximum: Double
    let actual: Double
    let target: Double
    let manual: Bool
}

struct FanStatus: Codable {
    let mode: FanMode?
    let fans: [FanReading]
}

struct FanError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

protocol FanSMC {
    func read(_ key: String) throws -> Double
    func write(_ key: String, _ value: Double) throws
}

// AppleSMC's private user-client protocol: 80 bytes, selector 2, commands
// 9 (key metadata), 5 (read), and 6 (write). Use explicit offsets instead of
// relying on Swift struct layout. Reads work without administrator privileges.
final class SMCConnection: FanSMC {
    private var connection: io_connect_t = 0

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw FanError(message: "This Mac does not expose fan controls.") }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else {
            throw FanError(message: String(format: "Cannot open AppleSMC (0x%08x).", result))
        }
    }

    deinit { IOServiceClose(connection) }

    private func call(_ key: String, command: UInt8, size: UInt32 = 0,
                      bytes: [UInt8] = []) throws -> [UInt8] {
        guard key.utf8.count == 4, bytes.count <= 32 else {
            throw FanError(message: "Invalid SMC request.")
        }
        var input = [UInt8](repeating: 0, count: 80)
        let code = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        input.withUnsafeMutableBytes {
            $0.storeBytes(of: code, toByteOffset: 0, as: UInt32.self)
            $0.storeBytes(of: size, toByteOffset: 28, as: UInt32.self)
        }
        input[42] = command
        input.replaceSubrange(48 ..< 48 + bytes.count, with: bytes)
        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = output.count
        let result = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                IOConnectCallStructMethod(connection, 2, source.baseAddress, source.count,
                                          destination.baseAddress, &outputSize)
            }
        }
        guard result == KERN_SUCCESS, outputSize == 80, output[40] == 0 else {
            throw FanError(message: String(format: "SMC %@ failed (IOKit 0x%08x, SMC 0x%02x).",
                                           key, result, output[40]))
        }
        return output
    }

    private func info(_ key: String) throws -> (size: UInt32, type: UInt32) {
        let data = try call(key, command: 9)
        return data.withUnsafeBytes {
            ($0.loadUnaligned(fromByteOffset: 28, as: UInt32.self),
             $0.loadUnaligned(fromByteOffset: 32, as: UInt32.self))
        }
    }

    func read(_ key: String) throws -> Double {
        let metadata = try info(key)
        let data = try call(key, command: 5, size: metadata.size)
        let value: Double
        switch (metadata.type, metadata.size) {
        case (0x666c7420, 4): // flt : little-endian IEEE-754 on Apple Silicon
            value = data.withUnsafeBytes { Double($0.loadUnaligned(fromByteOffset: 48, as: Float.self)) }
        case (0x66706532, 2): // fpe2: big-endian 14.2 fixed point
            value = Double(UInt16(data[48]) << 8 | UInt16(data[49])) / 4
        case (0x75693820, 1): value = Double(data[48]) // ui8
        default: throw FanError(message: "Unsupported SMC format for \(key).")
        }
        guard value.isFinite, value >= 0 else { throw FanError(message: "Invalid value for \(key).") }
        return value
    }

    func write(_ key: String, _ value: Double) throws {
        guard value.isFinite, value >= 0 else { throw FanError(message: "Invalid fan target.") }
        let metadata = try info(key)
        let bytes: [UInt8]
        switch (metadata.type, metadata.size) {
        case (0x666c7420, 4):
            guard value <= Double(Float.greatestFiniteMagnitude) else { throw FanError(message: "Invalid fan target.") }
            bytes = withUnsafeBytes(of: Float(value)) { Array($0) }
        case (0x66706532, 2):
            guard value < 16384 else { throw FanError(message: "Invalid fan target.") }
            let raw = UInt16((value * 4).rounded())
            bytes = [UInt8(raw >> 8), UInt8(raw & 0xff)]
        case (0x75693820, 1):
            guard value <= 255, value.rounded() == value else { throw FanError(message: "Invalid fan mode.") }
            bytes = [UInt8(value)]
        default: throw FanError(message: "Unsupported SMC format for \(key).")
        }
        _ = try call(key, command: 6, size: metadata.size, bytes: bytes)
    }
}

// All access belongs to the helper's serial queue. The UI cannot supply keys
// or arbitrary RPMs: the helper accepts only these three bounded presets.
final class FanHardware {
    private let smc: FanSMC
    private let pause: (TimeInterval) -> Void
    private let modeKeys: [String]
    private let hasUnlock: Bool
    private(set) var mode: FanMode? = .auto
    private(set) var needsRestore = false

    init(smc: FanSMC, pause: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)) throws {
        self.smc = smc
        self.pause = pause
        let count = try smc.read("FNum")
        guard (1 ... 10).contains(count), count.rounded() == count else {
            throw FanError(message: count == 0 ? "This Mac has no fans." : "Unsupported fan configuration.")
        }
        modeKeys = try (0 ..< Int(count)).map { index in
            let upper = "F\(index)Md"
            if (try? smc.read(upper)) != nil { return upper }
            let lower = "F\(index)md"
            _ = try smc.read(lower)
            return lower
        }
        hasUnlock = (try? smc.read("Ftst")) != nil
        let fans = try readings()
        if fans.contains(where: \.manual) { mode = nil }
    }

    func readings() throws -> [FanReading] {
        try modeKeys.indices.map { index in
            let low = try smc.read("F\(index)Mn")
            let high = try smc.read("F\(index)Mx")
            guard low.isFinite, high.isFinite, low > 0, high >= low, high < 30_000 else {
                throw FanError(message: "Invalid operating range for fan \(index + 1).")
            }
            return FanReading(index: index, minimum: low, maximum: high,
                              actual: try smc.read("F\(index)Ac"), target: try smc.read("F\(index)Tg"),
                              manual: try smc.read(modeKeys[index]) == 1)
        }
    }

    func status() throws -> FanStatus {
        let fans = try readings()
        let reported = !needsRestore && fans.contains(where: \.manual) ? nil : mode
        return FanStatus(mode: reported, fans: fans)
    }

    func set(_ selected: FanMode) throws {
        if selected == .auto { try restore(); return }
        let fans = try readings() // Validate every range before the first write.
        needsRestore = true
        do {
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            if hasUnlock { try smc.write("Ftst", 1) }
            for fan in fans {
                let key = modeKeys[fan.index]
                // M3/M4 thermal firmware can take several seconds to yield.
                var lastError: Error?
                for attempt in 0 ..< 100 {
                    if ProcessInfo.processInfo.systemUptime >= deadline { break }
                    do {
                        try smc.write(key, 1)
                        guard try smc.read(key) == 1 else { throw FanError(message: "Fan mode was not applied.") }
                        lastError = nil
                        break
                    } catch { lastError = error }
                    if attempt < 99 { pause(0.1) }
                }
                if let error = lastError { throw error }
                guard try smc.read(key) == 1 else { throw FanError(message: "Timed out setting manual fan mode.") }
                let target = selected == .max ? fan.maximum : (fan.minimum + fan.maximum) / 2
                try smc.write("F\(fan.index)Tg", target)
                let accepted = waitUntil(deadline: deadline) {
                    guard let actual = try? self.smc.read("F\(fan.index)Tg") else { return false }
                    return abs(actual - target) <= 2
                }
                guard accepted else {
                    let observed = (try? smc.read("F\(fan.index)Tg")) ?? -1
                    throw FanError(message: "Fan \(fan.index + 1) did not accept \(Int(target)) RPM (read back \(Int(observed)) RPM).")
                }
            }
            mode = selected
        } catch {
            let failure = error
            do { try restore() } catch {
                throw FanError(message: "\(failure.localizedDescription) Returning to Auto also failed: \(error.localizedDescription)")
            }
            throw failure
        }
    }

    func restore() throws {
        needsRestore = true
        mode = nil
        var failures: [String] = []
        // Attempt every reset even if one fan rejects a write.
        for key in modeKeys {
            do { try smc.write(key, 0) } catch { failures.append(error.localizedDescription) }
        }
        if hasUnlock {
            do { try smc.write("Ftst", 0) } catch { failures.append(error.localizedDescription) }
        }
        // Some firmware rejects redundant writes after already restoring Auto.
        let automatic = waitUntil {
            let modes = self.modeKeys.allSatisfy { key in
                guard let value = try? self.smc.read(key) else { return false }
                return value == 0 || value == 3
            }
            return modes && (!self.hasUnlock || (try? self.smc.read("Ftst")) == 0)
        }
        guard automatic else {
            throw FanError(message: failures.isEmpty ? "Could not verify automatic fan control." : failures.joined(separator: "\n"))
        }
        needsRestore = false
        mode = .auto
    }

    private func waitUntil(deadline: TimeInterval = .infinity, _ condition: () -> Bool) -> Bool {
        for attempt in 0 ..< 50 {
            if condition() { return true }
            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
            if attempt < 49 { pause(0.1) }
        }
        return false
    }
}
