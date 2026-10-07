import Foundation
import IOKit

// Owned by procQueue. Only opened and sampled while the dropdown is visible;
// no timer, subprocess, GPU user client, or driver-wide property enumeration.
final class SystemUsageMonitor {
    struct Snapshot {
        let gpuPercent: Int?
        let memoryUsed: UInt64?
        let memoryTotal: UInt64
    }

    private var accelerators: [io_service_t] = []
    private var host: host_t = 0
    private var pageSize: vm_size_t = 0
    private let memoryTotal = ProcessInfo.processInfo.physicalMemory

    func start() {
        stop()
        host = mach_host_self()
        if host_page_size(host, &pageSize) != KERN_SUCCESS { pageSize = 0 }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            accelerators.append(service)
        }
    }

    func stop() {
        for service in accelerators { IOObjectRelease(service) }
        accelerators.removeAll(keepingCapacity: true)
        if host != 0 { mach_port_deallocate(mach_task_self_, host) }
        host = 0
        pageSize = 0
    }

    deinit { stop() }

    func sample() -> Snapshot {
        // Show the busiest GPU on multi-GPU Macs. Missing driver counters must
        // remain unavailable rather than looking like a genuine 0% sample.
        var gpuPercent: Int?
        for service in accelerators {
            guard let statistics = IORegistryEntryCreateCFProperty(service,
                    "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let number = (statistics["Device Utilization %"]
                    ?? statistics["GPU Core Utilization"]) as? NSNumber else { continue }
            let percent = number.doubleValue
            guard percent.isFinite, (0...100).contains(percent) else { continue }
            gpuPercent = max(gpuPercent ?? 0, Int(percent.rounded()))
        }

        var memoryUsed: UInt64?
        if host != 0, pageSize != 0 {
            var statistics = vm_statistics64()
            var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride
                / MemoryLayout<integer_t>.stride)
            let result = withUnsafeMutablePointer(to: &statistics) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics64(host, HOST_VM_INFO64, $0, &count)
                }
            }
            if result == KERN_SUCCESS {
                // Resident app memory + wired + compressed physical pages.
                // Reclaimable file cache and purgeable pages are excluded.
                let appPages = UInt64(statistics.internal_page_count)
                let purgeable = min(appPages, UInt64(statistics.purgeable_count))
                let usedPages = appPages - purgeable + UInt64(statistics.wire_count)
                    + UInt64(statistics.compressor_page_count)
                memoryUsed = min(memoryTotal, usedPages * UInt64(pageSize))
            }
        }
        return Snapshot(gpuPercent: gpuPercent, memoryUsed: memoryUsed, memoryTotal: memoryTotal)
    }
}
