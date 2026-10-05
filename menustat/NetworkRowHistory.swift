import Foundation

// UI history only. Keep quiet processes around briefly without presenting old
// throughput as current activity. Confined to the main queue by AppDelegate.
struct NetworkRowHistory {
    struct Row: Equatable {
        let pid: Int32
        let name: String
        let bytesInPerSec: UInt64
        let bytesOutPerSec: UInt64
    }

    private struct Entry {
        let row: Row
        let lastActive: TimeInterval
    }

    let retention: TimeInterval
    private var entries: [Int32: Entry] = [:]

    init(retention: TimeInterval = 3) {
        self.retention = retention
    }

    mutating func reset() {
        entries.removeAll(keepingCapacity: true)
    }

    // Incoming rows are already sorted by live throughput. Active processes
    // take priority; recently idle entries fill the remaining visible slots.
    mutating func update(_ rows: [Row], at now: TimeInterval, limit: Int) -> [Row] {
        let active = rows.filter { $0.bytesInPerSec > 0 || $0.bytesOutPerSec > 0 }
        let activePIDs = Set(active.map(\.pid))
        for row in active {
            entries[row.pid] = Entry(row: row, lastActive: now)
        }
        entries = entries.filter { now - $0.value.lastActive < retention }

        let idle = entries.values.filter { !activePIDs.contains($0.row.pid) }.sorted {
            if $0.lastActive != $1.lastActive { return $0.lastActive > $1.lastActive }
            let left = $0.row.bytesInPerSec + $0.row.bytesOutPerSec
            let right = $1.row.bytesInPerSec + $1.row.bytesOutPerSec
            return left != right ? left > right : $0.row.pid < $1.row.pid
        }.map { Row(pid: $0.row.pid, name: $0.row.name, bytesInPerSec: 0, bytesOutPerSec: 0) }

        return Array((active + idle).prefix(max(0, limit)))
    }
}
