import Cocoa

// Optional integration check: requires a logged-in macOS GUI session. Briefly
// creates a status item and exercises the real kernel/framework data sources.
@main struct LiveSmoke {
    static func main() throws {
        let load = Process()
        load.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        load.standardOutput = FileHandle.nullDevice
        try load.run()
        let monitor = ProcMonitor()
        let measuredPercent: Double?
        do {
            defer { load.terminate(); load.waitUntilExit() }
            Thread.sleep(forTimeInterval: 0.1)
            _ = monitor.topCPUProcesses(10)
            Thread.sleep(forTimeInterval: 0.6)
            measuredPercent = monitor.topCPUProcesses(10).first {
                $0.pid == load.processIdentifier
            }?.cpuPercent
        }
        // Stop the load before assertions: a precondition trap does not run defer.
        guard let percent = measuredPercent else { fatalError("Busy child missing from top ten") }
        precondition(percent > 50 && percent < 120, "Incorrect live CPU units, or host too busy")

        NSApplication.shared.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let menu = delegate.menuItem.menu!
        func wait(_ seconds: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        delegate.menuWillOpen(menu)
        wait(2.5)
        let rows = menu.items.compactMap { $0.view as? MenuRowView }
        precondition(!delegate.menuItem.button!.attributedTitle.string.isEmpty, "Status totals did not arrive")
        precondition(rows.contains {
            $0.valueField.stringValue.hasSuffix("%") && $0.nameField.stringValue != "Cores"
        }, "CPU rows did not arrive")
        precondition(!rows.contains {
            ["measuring…", "Unavailable"].contains($0.nameField.stringValue)
        }, "Network backend unavailable or callback did not arrive")

        for _ in 0..<20 {
            delegate.menuDidClose(menu)
            delegate.menuWillOpen(menu)
            wait(0.01)
        }
        wait(2.2)
        delegate.menuDidClose(menu)
        wait(0.2)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        print("PASS: busy process at \(percent)% CPU, live status/menu sampling, 20 close/reopen cycles")
    }
}
