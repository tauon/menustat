import Foundation

// Module-local replacements exercise the production sampler without depending
// on process timing, permissions, or PID ordering on the test machine.
private var ticks: UInt64 = 1_000
private var cpuTimes = (0...260).map { UInt64($0) + UInt64.max / 4 }
private var startTimes = [UInt64](repeating: 1, count: 261)
private var sampled: [pid_t] = []
private var names: [pid_t] = []
private var sizeQueries = 0
private var listQueries = 0

func mach_absolute_time() -> UInt64 { ticks }

func proc_listallpids(_ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32 {
    guard let buffer = buffer else {
        sizeQueries += 1
        return 1 // Simulate a process burst after the initial size query.
    }
    listQueries += 1
    let count = min(Int(size) / MemoryLayout<pid_t>.size, 260)
    let pids = buffer.assumingMemoryBound(to: pid_t.self)
    for i in 0..<count { pids[i] = pid_t(i + 1) }
    return Int32(count)
}

func proc_pid_rusage(_ pid: pid_t, _ flavor: Int32,
                     _ buffer: UnsafeMutablePointer<rusage_info_t?>) -> Int32 {
    precondition(flavor == RUSAGE_INFO_V0)
    sampled.append(pid)
    if pid == 2 { return -1 } // A process we cannot inspect.
    let info = UnsafeMutableRawPointer(buffer).assumingMemoryBound(to: rusage_info_v0.self)
    info.pointee.ri_user_time = cpuTimes[Int(pid)]
    info.pointee.ri_proc_start_abstime = startTimes[Int(pid)]
    return 0
}

func proc_name(_ pid: pid_t, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32 {
    names.append(pid)
    let name = "process-\(pid)"
    name.withCString { _ = strlcpy(buffer.assumingMemoryBound(to: CChar.self), $0, Int(size)) }
    return Int32(name.utf8.count)
}

@main struct ProcMonitorTests {
    static func main() {
        let monitor = ProcMonitor()
        precondition(monitor.topCPUProcesses(10).isEmpty)
        precondition(sampled.count == 260 && sampled.last == 260, "Must inspect the entire PID list")
        precondition(names.isEmpty, "Baseline sampling needs no process names")
        precondition(sizeQueries == 1 && listQueries == 4, "Retry full PID buffers")

        ticks += 1_000
        for pid in 1...260 { cpuTimes[pid] += UInt64(pid * 10) }
        let top = monitor.topCPUProcesses(10)
        precondition(top.map(\.pid) == Array((251...260).reversed()).map(pid_t.init))
        precondition(abs(top[0].cpuPercent - 260) < 0.0001, "Mach tick ratios support multi-core use")
        precondition(names.count == 10, "Only displayed processes need name lookups")
        precondition(sizeQueries == 1 && listQueries == 5, "Reuse the PID buffer")

        // A reused PID with a larger cumulative CPU time still needs a new baseline.
        ticks += 1_000
        startTimes[260] = 2
        cpuTimes[260] += 1_000_000
        cpuTimes[259] = 0 // A backwards counter must also be ignored.
        let next = monitor.topCPUProcesses(260)
        precondition(!next.contains { [2, 259, 260].contains($0.pid) })
        precondition(next.allSatisfy { $0.cpuPercent == 0 })
        precondition(next.first?.pid == 1, "Ties must have stable ordering")

        monitor.reset()
        ticks += 1_000
        precondition(monitor.topCPUProcesses(10).isEmpty, "Reopening needs a fresh baseline")
        precondition(monitor.topCPUProcesses(0).isEmpty)
        precondition(monitor.topCPUProcesses(-1).isEmpty)
        print("PASS: complete PID enumeration, buffer growth/reuse, top ten, CPU units, PID reuse, reset")
    }
}
