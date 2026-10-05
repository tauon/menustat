import Foundation

@main struct NetworkRowHistoryTests {
    static func main() {
        typealias Row = NetworkRowHistory.Row
        let download = Row(pid: 1, name: "Download", bytesInPerSec: 1_000, bytesOutPerSec: 0)
        let upload = Row(pid: 2, name: "Upload", bytesInPerSec: 0, bytesOutPerSec: 500)
        var history = NetworkRowHistory()
        precondition(history.update([download], at: 10, limit: 5) == [download])
        let idle = history.update([], at: 11, limit: 5)
        precondition(idle.count == 1 && idle[0].name == "Download")
        precondition(idle[0].bytesInPerSec == 0 && idle[0].bytesOutPerSec == 0,
                     "An idle row must not claim the previous throughput")
        precondition(history.update([], at: 12.99, limit: 5).count == 1)
        precondition(history.update([], at: 13, limit: 5).isEmpty)

        _ = history.update([download], at: 20, limit: 5)
        let resumed = history.update([download], at: 22, limit: 5)
        precondition(resumed == [download], "New activity must restore the live rate")
        let mixed = history.update([upload], at: 23, limit: 5)
        precondition(mixed.map(\.pid) == [2, 1], "Live traffic ranks above idle rows")
        precondition(mixed[1].bytesInPerSec == 0)
        precondition(history.update([upload], at: 24, limit: 1) == [upload])
        precondition(history.update([], at: 24.99, limit: 5).contains { $0.pid == 1 },
                     "New activity must extend the retention window")
        precondition(!history.update([], at: 25, limit: 5).contains { $0.pid == 1 })
        history.reset()
        precondition(history.update([], at: 25.1, limit: 5).isEmpty,
                     "A new menu session must not show old processes")
        print("PASS: three-second network row retention, truthful idle rates, ranking, resume, reset")
    }
}
