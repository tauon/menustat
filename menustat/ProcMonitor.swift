import Foundation

struct ProcCPUUsage {
    let pid: pid_t
    let name: String
    let cpuPercent: Double
}

struct ProcNetUsage {
    let name: String
    let bytesInPerSec: UInt64
    let bytesOutPerSec: UInt64
}

// Per-process CPU and network usage for the dropdown menu. CPU comes from
// libproc rusage deltas (processes owned by other users are skipped because
// proc_pid_rusage denies access to them). Network comes from nettop, since
// macOS has no public per-process byte-count API; nettop works without root.
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

    // MARK: - CPU

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

    // MARK: - Network

    // Blocks for ~intervalSeconds while nettop measures per-process deltas.
    // Returns nil if nettop fails.
    static func topNetProcesses(_ count: Int, intervalSeconds: Int = 1) -> [ProcNetUsage]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // -d makes the second of the two logged samples a per-interval delta
        task.arguments = ["-P", "-x", "-d",
                          "-J", "bytes_in,bytes_out",
                          "-L", "2",
                          "-s", String(intervalSeconds)]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Output is two CSV blocks, each headed by a "time,..." line:
        //   time,,bytes_in,bytes_out,
        //   12:38:54.401049,mDNSResponder.712,287,131,
        // The first block is cumulative since boot; only the delta block counts.
        var usages: [ProcNetUsage] = []
        var headersSeen = 0
        for line in output.split(separator: "\n") {
            if line.hasPrefix("time,") {
                headersSeen += 1
                continue
            }
            guard headersSeen >= 2 else { continue }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 4,
                  let bytesIn = UInt64(fields[2]),
                  let bytesOut = UInt64(fields[3]),
                  bytesIn + bytesOut > 0 else { continue }
            // strip the ".pid" suffix nettop appends to the process name
            var name = String(fields[1])
            if let dot = name.lastIndex(of: ".") {
                name = String(name[..<dot])
            }
            usages.append(ProcNetUsage(name: name,
                                       bytesInPerSec: bytesIn / UInt64(intervalSeconds),
                                       bytesOutPerSec: bytesOut / UInt64(intervalSeconds)))
        }

        return Array(usages
            .sorted { $0.bytesInPerSec + $0.bytesOutPerSec > $1.bytesInPerSec + $1.bytesOutPerSec }
            .prefix(count))
    }
}
