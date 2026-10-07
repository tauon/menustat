import Foundation

private final class FakeSMC: FanSMC {
    var values: [String: Double] = [
        "FNum": 2, "Ftst": 0,
        "F0Mn": 2000, "F0Mx": 6000, "F0Ac": 2400, "F0Tg": 2400, "F0Md": 3,
        "F1Mn": 2500, "F1Mx": 7500, "F1Ac": 2700, "F1Tg": 2700, "F1Md": 3
    ]
    var writes: [(String, Double)] = []
    var rejectedWrites: Set<String> = []
    var unlockAttempts = 0
    var yieldAfter = 0
    var delayedWrites = false
    var pending: [String: (Int, Double)] = [:]

    func read(_ key: String) throws -> Double {
        if let (remaining, value) = pending[key] {
            if remaining == 0 { values[key] = value; pending.removeValue(forKey: key) }
            else { pending[key] = (remaining - 1, value) }
        }
        guard let value = values[key] else { throw FanError(message: "Missing \(key)") }
        return value
    }

    func write(_ key: String, _ value: Double) throws {
        writes.append((key, value))
        if rejectedWrites.contains(key) { throw FanError(message: "Rejected \(key)") }
        if key == "F0Md", value == 1 {
            unlockAttempts += 1
            if unlockAttempts <= yieldAfter { throw FanError(message: "Firmware still in system mode") }
        }
        if delayedWrites, key.hasSuffix("Tg") || key.hasSuffix("Md") && value == 0 {
            pending[key] = (2, value)
        } else { values[key] = value }
    }
}

@main struct FanHardwareTests {
    static func main() throws {
        let smc = FakeSMC()
        var pauses = 0
        let hardware = try FanHardware(smc: smc, pause: { _ in pauses += 1 })
        precondition(smc.writes.isEmpty, "Discovery must never alter another controller's settings")
        smc.yieldAfter = 3
        try hardware.set(.medium)
        precondition(pauses == 3)
        precondition(smc.values["F0Tg"] == 4000 && smc.values["F1Tg"] == 5000)
        precondition(hardware.mode == .medium && hardware.needsRestore)
        try hardware.set(.max)
        precondition(smc.values["F0Tg"] == 6000 && smc.values["F1Tg"] == 7500)
        try hardware.restore()
        precondition(smc.values["F0Md"] == 0 && smc.values["F1Md"] == 0 && smc.values["Ftst"] == 0)
        precondition(hardware.mode == .auto && !hardware.needsRestore)

        // A failure after the first fan changed must roll both fans back.
        smc.rejectedWrites = ["F1Tg"]
        do { try hardware.set(.max); fatalError("Expected rejected target") } catch { }
        precondition(hardware.mode == .auto && !hardware.needsRestore)
        precondition(smc.values["F0Md"] == 0 && smc.values["F1Md"] == 0 && smc.values["Ftst"] == 0)

        // Failed resets stay pending, but must still try every fan and unlock flag.
        smc.rejectedWrites = []
        try hardware.set(.medium)
        smc.rejectedWrites = ["F0Md"]
        do { try hardware.restore(); fatalError("Expected incomplete reset") } catch { }
        precondition(hardware.needsRestore && hardware.mode == nil)
        precondition(smc.values["F1Md"] == 0 && smc.values["Ftst"] == 0)
        smc.rejectedWrites = []
        try hardware.restore()
        precondition(!hardware.needsRestore)

        let invalid = FakeSMC()
        invalid.values["F1Mx"] = .nan
        do { _ = try FanHardware(smc: invalid); fatalError("Expected invalid range") } catch { }
        precondition(invalid.writes.isEmpty)
        invalid.values["FNum"] = 0
        do { _ = try FanHardware(smc: invalid); fatalError("Expected fanless Mac") } catch { }

        let lower = FakeSMC()
        lower.values["F0md"] = 1
        lower.values["F1md"] = 1
        lower.values.removeValue(forKey: "F0Md")
        lower.values.removeValue(forKey: "F1Md")
        lower.values.removeValue(forKey: "Ftst")
        let external = try FanHardware(smc: lower, pause: { _ in })
        precondition(external.mode == nil && lower.writes.isEmpty)
        try external.set(.max)
        try external.set(.auto)
        precondition(lower.values["F0md"] == 0 && lower.values["F1md"] == 0)
        let asynchronous = FakeSMC()
        asynchronous.delayedWrites = true
        let delayed = try FanHardware(smc: asynchronous, pause: { _ in })
        try delayed.set(.max)
        precondition(asynchronous.values["F0Tg"] == 6000 && asynchronous.values["F1Tg"] == 7500)
        try delayed.restore()
        precondition(delayed.mode == .auto && !delayed.needsRestore)
        print("PASS: bounded fan presets, firmware retry, partial-failure rollback, reset retry, external control, unsupported hardware")
    }
}
