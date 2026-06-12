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

    private var lastCPUTimes: [pid_t: UInt64] = [:]
    private var lastSampleTimeNs: UInt64 = 0
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    // Returns the top processes by CPU since the previous call; empty on the
    // first call (no baseline yet). Percentages are per-core, so a process
    // with several busy threads can exceed 100, like Activity Monitor.
    func topCPUProcesses(_ count: Int) -> [ProcCPUUsage] {
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        var currentTimes: [pid_t: UInt64] = [:]
        currentTimes.reserveCapacity(lastCPUTimes.count + 16)
        var usages: [ProcCPUUsage] = []

        let elapsedNs = now - lastSampleTimeNs
        let havePrevious = lastSampleTimeNs != 0 && elapsedNs > 0

        for pid in allPids() {
            var info = rusage_info_current()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            guard ok == 0 else { continue }

            let cpuTimeNs = machTimeToNs(info.ri_user_time + info.ri_system_time)
            currentTimes[pid] = cpuTimeNs

            // A pid absent from the previous sample is new (or a reused pid);
            // it has no baseline, so it joins the list next sample.
            guard havePrevious, let previous = lastCPUTimes[pid], cpuTimeNs >= previous else {
                continue
            }
            let percent = Double(cpuTimeNs - previous) / Double(elapsedNs) * 100.0
            usages.append(ProcCPUUsage(pid: pid, name: processName(pid), cpuPercent: percent))
        }

        lastCPUTimes = currentTimes
        lastSampleTimeNs = now

        return Array(usages.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(count))
    }

    private func allPids() -> [pid_t] {
        let expected = proc_listallpids(nil, 0)
        guard expected > 0 else { return [] }
        // headroom for processes spawned between the two calls
        var pids = [pid_t](repeating: 0, count: Int(expected) + 64)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        let count = min(Int(bytes) / MemoryLayout<pid_t>.size, pids.count)
        return Array(pids.prefix(count)).filter { $0 > 0 }
    }

    private func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else {
            return "pid \(pid)"
        }
        return String(cString: buffer)
    }

    private func machTimeToNs(_ machTime: UInt64) -> UInt64 {
        return machTime * UInt64(timebase.numer) / UInt64(timebase.denom)
    }
}
