import Cocoa

// Requires an idle GUI session: opening another menu or clicking elsewhere is
// expected to dismiss an NSMenu. Unlike LiveSmoke, this enters real tracking.
final class MenuTrackingDelegate: AppDelegate {
    private var opens = 0
    private var openedAt = 0.0
    private var expectedClose = false
    private var finished = false

    override func applicationDidFinishLaunching(_ notification: Notification) {
        super.applicationDidFinishLaunching(notification)
        scheduleOpen(after: 1.5)
        RunLoop.main.add(Timer(timeInterval: 12, repeats: false) { _ in
            fputs("FAIL: menu tracking timed out\n", stderr)
            exit(1)
        }, forMode: .common)
    }

    private func scheduleOpen(after delay: TimeInterval) {
        RunLoop.main.add(Timer(timeInterval: delay, repeats: false) { _ in
            guard let button = self.menuItem.button, let window = button.window else {
                fatalError("Missing status button")
            }
            if self.opens == 0 {
                button.performClick(nil)
            } else {
                // Exercise a mouse-down/up pair in this app without global
                // event injection or Accessibility permission.
                let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                func event(_ type: NSEvent.EventType) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
                }
                RunLoop.main.add(Timer(timeInterval: 0.1, repeats: false) { _ in
                    NSApp.postEvent(event(.leftMouseUp), atStart: true)
                }, forMode: .common)
                button.mouseDown(with: event(.leftMouseDown))
            }
        }, forMode: .common)
    }

    override func menuWillOpen(_ menu: NSMenu) {
        opens += 1
        openedAt = ProcessInfo.processInfo.systemUptime
        expectedClose = false
        super.menuWillOpen(menu)
        let quitIndex = menu.items.firstIndex { $0.title == "Quit" }!
        precondition(menu.items[quitIndex - 1].title.hasPrefix("Build "))
        precondition(!menu.items[quitIndex - 1].isEnabled)
        RunLoop.main.add(Timer(timeInterval: 2.2, repeats: false) { _ in
            self.expectedClose = true
            menu.cancelTracking()
        }, forMode: .common)
    }

    override func menuDidClose(_ menu: NSMenu) {
        super.menuDidClose(menu)
        guard !finished else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - openedAt
        guard expectedClose, elapsed >= 2 else {
            fputs("FAIL: menu closed after \(elapsed)s without cancellation\n", stderr)
            exit(1)
        }
        if opens < 2 {
            scheduleOpen(after: 0.3)
        } else {
            finished = true
            print("PASS: native menu tracking stayed open across updates, click and mouse-down/up, build label")
            NSApp.terminate(nil)
        }
    }
}

@main struct MenuTrackingSmoke {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = MenuTrackingDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
