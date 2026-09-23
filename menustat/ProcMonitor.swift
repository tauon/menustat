import Foundation

struct ProcCPUUsage {
    let pid: pid_t
    let name: String
    let cpuPercent: Double
}

// Per-process CPU usage from libproc rusage deltas. Processes owned by other
// users are skipped because proc_pid_rusage denies access to them.
//
// Not thread-safe: call from a single serial queue.
final class ProcMonitor {

    private struct Sample {
        let startTime: UInt64
        let cpuTime: UInt64
    }

    private var lastSamples: [pid_t: Sample] = [:]
    private var currentSamples: [pid_t: Sample] = [:]
    private var lastSampleTime: UInt64 = 0
    private var pidBuffer: [pid_t] = []

    // A reopened menu needs a fresh baseline, not an average over the time
    // it was closed. Retain the storage for the next sampling session.
    func reset() {
        lastSamples.removeAll(keepingCapacity: true)
        currentSamples.removeAll(keepingCapacity: true)
        lastSampleTime = 0
    }

    // Returns the top processes by CPU since the previous call; empty on the
    // first call (no baseline yet). Percentages are per-core, so a process
    // with several busy threads can exceed 100, like Activity Monitor.
    func topCPUProcesses(_ count: Int) -> [ProcCPUUsage] {
        guard count > 0 else { return [] }
        // rusage CPU times and mach_absolute_time use the same Mach ticks.
        // Taking their ratio avoids conversions (and cumulative overflow).
        let now = mach_absolute_time()
        let elapsed = now - lastSampleTime
        let havePrevious = lastSampleTime != 0 && elapsed > 0
        let pidCount = loadPids()
        currentSamples.removeAll(keepingCapacity: true)
        currentSamples.reserveCapacity(lastSamples.count + 16)
        var top: [(pid: pid_t, percent: Double)] = []
        top.reserveCapacity(min(count, pidCount))

        for pid in pidBuffer.prefix(pidCount) where pid > 0 {
            // V0 contains everything needed here. CURRENT asks the kernel
            // for additional accounting and can change with a newer SDK.
            var info = rusage_info_v0()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V0, $0)
                }
            }
            guard ok == 0 else { continue }

            let cpuTime = info.ri_user_time + info.ri_system_time
            currentSamples[pid] = Sample(startTime: info.ri_proc_start_abstime, cpuTime: cpuTime)

            // New processes and reused PIDs need their own baseline.
            guard havePrevious, let previous = lastSamples[pid],
                  previous.startTime == info.ri_proc_start_abstime,
                  cpuTime >= previous.cpuTime else {
                continue
            }
            let percent = Double(cpuTime - previous.cpuTime) / Double(elapsed) * 100.0
            // Keep only the requested rows, with deterministic PID ordering
            // for ties. Resolve names only after choosing the winners.
            let index = top.firstIndex {
                percent > $0.percent || (percent == $0.percent && pid < $0.pid)
            } ?? top.endIndex
            if index < count {
                top.insert((pid, percent), at: index)
                if top.count > count { top.removeLast() }
            }
        }

        swap(&lastSamples, &currentSamples)
        lastSampleTime = now

        return top.map { ProcCPUUsage(pid: $0.pid, name: processName($0.pid), cpuPercent: $0.percent) }
    }

    private func loadPids() -> Int {
        if pidBuffer.isEmpty {
            let expected = proc_listallpids(nil, 0)
            guard expected > 0 else { return 0 }
            pidBuffer = [pid_t](repeating: 0, count: Int(expected) + 64)
        }
        // Usually one syscall into reused storage. Retry a full buffer so a
        // process burst cannot silently truncate the list.
        for _ in 0..<4 {
            let count = proc_listallpids(&pidBuffer, Int32(pidBuffer.count * MemoryLayout<pid_t>.size))
            guard count > 0 else { return 0 }
            // Unlike proc_listpids, proc_listallpids returns a PID count.
            if Int(count) < pidBuffer.count { return Int(count) }
            pidBuffer += [pid_t](repeating: 0, count: pidBuffer.count)
        }
        return 0
    }

    private func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else {
            return "pid \(pid)"
        }
        return String(cString: buffer)
    }
}
