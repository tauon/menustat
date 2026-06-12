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

// Streams per-process network rates from a long-running nettop, since macOS
// has no public per-process byte-count API (nettop works without root).
//
// nettop writes to a pty we allocate, not a pipe: stdio block-buffers pipe
// output, which only flushes every ~4 samples and made readings lag by
// several seconds.
final class NetTopStream {

    private let task = Process()
    private var masterHandle: FileHandle?
    private var slaveHandle: FileHandle?

    private let lock = NSLock()
    private var latestRows: [ProcNetUsage]?

    // Parser state, only touched from the readability handler's queue.
    private var lineRemainder = ""
    private var blockIndex = 0
    private var currentRows: [ProcNetUsage] = []

    func start() {
        let masterFD = posix_openpt(O_RDWR | O_NOCTTY)
        guard masterFD >= 0 else { return }
        guard grantpt(masterFD) == 0, unlockpt(masterFD) == 0,
              let slaveName = ptsname(masterFD) else {
            close(masterFD)
            return
        }
        let slaveFD = open(String(cString: slaveName), O_RDWR | O_NOCTTY)
        guard slaveFD >= 0 else {
            close(masterFD)
            return
        }
        let master = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        masterHandle = master
        slaveHandle = slave

        task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // -d makes every sample after the first a per-interval delta
        task.arguments = ["-P", "-x", "-d",
                          "-J", "bytes_in,bytes_out",
                          "-L", "0", "-s", "1"]
        task.standardOutput = slave
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice

        master.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self = self, !data.isEmpty else {
                // EOF (nettop died) or the stream is gone; stop spinning
                handle.readabilityHandler = nil
                return
            }
            self.consume(data)
        }

        do {
            try task.run()
        } catch {
            master.readabilityHandler = nil
            masterHandle = nil
            slaveHandle = nil
        }
    }

    func stop() {
        masterHandle?.readabilityHandler = nil
        if task.isRunning {
            task.terminate()
        }
        try? slaveHandle?.close()
        try? masterHandle?.close()
        masterHandle = nil
        slaveHandle = nil
    }

    // nil until the first delta sample has arrived (~2s after start).
    func latest(top count: Int) -> [ProcNetUsage]? {
        lock.lock()
        let rows = latestRows
        lock.unlock()
        guard let rows = rows else { return nil }
        return Array(rows
            .sorted { $0.bytesInPerSec + $0.bytesOutPerSec > $1.bytesInPerSec + $1.bytesOutPerSec }
            .prefix(count))
    }

    private func consume(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        var lines = (lineRemainder + chunk).components(separatedBy: "\n")
        lineRemainder = lines.removeLast()

        for rawLine in lines {
            // the pty produces \r\n line endings
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.hasPrefix("time,") {
                blockIndex += 1
                currentRows = []
                continue
            }
            // block 1 is cumulative since boot; deltas start with block 2
            guard blockIndex >= 2, let row = NetTopStream.parseRow(line) else { continue }
            currentRows.append(row)
        }

        // A block's rows arrive as one burst right after its header, so
        // publishing after each chunk converges on the complete block well
        // before the next sample.
        if blockIndex >= 2 && !currentRows.isEmpty {
            lock.lock()
            latestRows = currentRows
            lock.unlock()
        }
    }

    // Sample lines look like: 12:38:54.401049,mDNSResponder.712,287,131,
    private static func parseRow(_ line: String) -> ProcNetUsage? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 4,
              let bytesIn = UInt64(fields[2]),
              let bytesOut = UInt64(fields[3]),
              bytesIn + bytesOut > 0 else { return nil }
        // strip the ".pid" suffix nettop appends to the process name
        var name = String(fields[1])
        if let dot = name.lastIndex(of: ".") {
            name = String(name[..<dot])
        }
        return ProcNetUsage(name: name, bytesInPerSec: bytesIn, bytesOutPerSec: bytesOut)
    }
}
