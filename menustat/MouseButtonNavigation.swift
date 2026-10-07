import Cocoa
import ApplicationServices

// Owned by the main run loop, including the event-tap callback. Mouse events
// drive all work; this feature does not monitor keyboard input or poll focus.
final class MouseButtonNavigation: NSObject {
    // Preserve the existing toggle preference from the Safari-only version.
    private let preferenceKey = "SafariMouseButtonsEnabled"
    private var enabled: Bool {
        get { UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
    }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []
    private var consumedButtons: Set<Int64> = []
    private var lastScrollTabTime: TimeInterval = 0
    private var lastScrollTabPID: pid_t = 0
    private var lastScrollTabDirection = 0
    let menuItem = NSMenuItem(title: "Mouse Button Navigation", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Enabled", action: nil, keyEquivalent: "")
    private let statusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "Allow Accessibility…", action: nil, keyEquivalent: "")

    override init() {
        super.init()
        let menu = NSMenu(title: menuItem.title)
        menu.autoenablesItems = false
        toggleItem.target = self
        toggleItem.action = #selector(toggle)
        permissionItem.target = self
        permissionItem.action = #selector(requestPermission)
        statusItem.isEnabled = false
        menu.addItem(toggleItem)
        menu.addItem(statusItem)
        menu.addItem(permissionItem)
        menuItem.submenu = menu
        menuItem.toolTip = "Safari/Finder: Back/Forward. Kitty: tabs. Safari Command-scroll: tabs."
    }

    func start() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
    }

    func stop() {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        removeTap()
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        if !enabled || !trusted {
            removeTap()
        } else if tap == nil {
            installTap()
        } else if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        toggleItem.state = enabled ? .on : .off
        permissionItem.isHidden = trusted
        statusItem.title = !enabled ? "Off" : !trusted ? "Needs Accessibility permission" :
            tap == nil ? "Mouse listener unavailable — try restarting" : "Ready: button 4 ← / button 5 →"
    }

    @objc private func toggle() {
        enabled.toggle()
        if enabled && !AXIsProcessTrusted() { requestPermission() }
        refresh()
    }

    @objc private func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refresh()
    }

    private func installTap() {
        let mask = [CGEventType.otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<MouseButtonNavigation>.fromOpaque(context).takeUnretainedValue()
                return owner.handle(type: type, event: event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        consumedButtons.removeAll()
        lastScrollTabTime = 0
        lastScrollTabPID = 0
        lastScrollTabDirection = 0
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            consumedButtons.removeAll()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if type == .scrollWheel { return handleScroll(event) }

        // Quartz numbers buttons from zero: 0/1/2 are left/right/middle.
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        guard button == 3 || button == 4 else { return Unmanaged.passUnretained(event) }
        if type == .otherMouseUp {
            return consumedButtons.remove(button) != nil ? nil : Unmanaged.passUnretained(event)
        }
        if type == .otherMouseDragged {
            return consumedButtons.contains(button) ? nil : Unmanaged.passUnretained(event)
        }
        guard type == .otherMouseDown else { return Unmanaged.passUnretained(event) }
        if consumedButtons.contains(button) { return nil }

        guard let app = NSWorkspace.shared.frontmostApplication else { return Unmanaged.passUnretained(event) }
        let modifiers: CGEventFlags
        switch app.bundleIdentifier {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.apple.finder":
            modifiers = .maskCommand
        case "net.kovidgoyal.kitty":
            modifiers = [.maskCommand, .maskShift]
        default:
            return Unmanaged.passUnretained(event)
        }
        guard sendShortcut(key: button == 3 ? 33 : 30, modifiers: modifiers, pid: app.processIdentifier)
        else { return Unmanaged.passUnretained(event) }

        consumedButtons.insert(button)
        return nil
    }

    private func handleScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        // Ordinary scrolling takes only this flag check: no app/window lookup.
        guard event.flags.contains(.maskCommand),
              let app = NSWorkspace.shared.frontmostApplication,
              ["com.apple.Safari", "com.apple.SafariTechnologyPreview"].contains(app.bundleIdentifier ?? "")
        else { return Unmanaged.passUnretained(event) }

        // Ignore inertial tails and leave horizontal scrolling alone.
        let delta = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        guard delta != 0 else { return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 { return nil }
        // Follow physical wheel direction even with macOS Natural Scrolling on.
        let inverted = NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice == true
        let direction = (inverted ? -delta : delta) > 0 ? -1 : 1
        let time = TimeInterval(event.timestamp) / 1_000_000_000
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        // A smooth wheel/trackpad can send hundreds of events per second. Cap
        // same-direction tab changes at one per 150 ms, without a timer.
        if continuous && app.processIdentifier == lastScrollTabPID && direction == lastScrollTabDirection &&
            time - lastScrollTabTime < 0.15 { return nil }
        guard sendShortcut(key: direction < 0 ? 33 : 30,
                           modifiers: [.maskCommand, .maskShift], pid: app.processIdentifier)
        else { return Unmanaged.passUnretained(event) }
        lastScrollTabTime = time
        lastScrollTabPID = app.processIdentifier
        lastScrollTabDirection = direction
        return nil
    }

    @discardableResult
    private func sendShortcut(key: CGKeyCode, modifiers: CGEventFlags, pid: pid_t) -> Bool {
        guard let eventSource = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: eventSource, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: eventSource, virtualKey: key, keyDown: false)
        else { return false }

        down.flags = modifiers
        up.flags = modifiers
        // Target the frontmost supported process explicitly so a focus change cannot send
        // the generated shortcut to another app. Consume the entire click.
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }
}
