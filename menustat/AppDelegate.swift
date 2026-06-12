import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    @IBOutlet weak var window: NSWindow!
    var menuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let cpuInfo = CPUInfo()
    let netInfo = NetInfo()
    var eCoreCount = 0
    let updateIntervalSeconds: TimeInterval = 1
    let fontSize: CGFloat = 8
    let topProcessCount = 5

    // CPUInfo and NetInfo keep mutable state between samples, so all sampling
    // runs on this single serial queue.
    private let sampleQueue = DispatchQueue(label: "menustat.sample", qos: .utility)
    private var updateTimer: DispatchSourceTimer?

    // Per-process sampling only runs while the dropdown is open. ProcMonitor
    // state is confined to this queue; it's .userInitiated because the user
    // is actively looking at the menu.
    private let procQueue = DispatchQueue(label: "menustat.proc", qos: .userInitiated)
    private let procMonitor = ProcMonitor()
    private var menuGeneration = 0

    // Latest cluster usage, written and read on the main queue.
    private var latestECoreUsage = 0
    private var latestPCoreUsage = 0

    private var clusterHeaderItem: NSMenuItem!
    private var cpuRowItems: [NSMenuItem] = []
    private var netRowItems: [NSMenuItem] = []

    private lazy var menuFont = NSFont(name: "Menlo", size: 11)
        ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    private lazy var paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byCharWrapping
        style.alignment = .left
        style.lineSpacing = -4
        style.maximumLineHeight = fontSize
        style.minimumLineHeight = fontSize
        return style
    }()

    private lazy var baseAttributes: [NSAttributedString.Key: Any] = [
        .paragraphStyle: paragraphStyle,
        .foregroundColor: NSColor.controlTextColor
    ]

    private lazy var yellowAttributes: [NSAttributedString.Key: Any] = [
        .paragraphStyle: paragraphStyle,
        .foregroundColor: NSColor.yellow
    ]

    private lazy var redAttributes: [NSAttributedString.Key: Any] = [
        .paragraphStyle: paragraphStyle,
        .foregroundColor: NSColor.red
    ]

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        eCoreCount = getEfficiencyCoreCount()

        if let button = menuItem.button {
            button.image = nil
            button.title = ""
            button.font = NSFont(name: "Menlo", size: fontSize)
        }
        menuItem.menu = buildStatusMenu()

        // A dispatch timer on the sample queue coalesces missed fires, so
        // ticks can never pile up and run concurrently.
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(
            deadline: .now() + updateIntervalSeconds,
            repeating: updateIntervalSeconds,
            leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.update()
        }
        timer.resume()
        updateTimer = timer
    }

    // perflevel1 is the efficiency cluster (perflevel0 is performance), and
    // host_processor_info lists E-cores first on Apple Silicon. On Intel the
    // sysctl fails, leaving 0, and every core is treated as a P-core.
    func getEfficiencyCoreCount() -> Int {
        var count: Int = 0
        var size = MemoryLayout<Int>.size
        sysctlbyname("hw.perflevel1.logicalcpu", &count, &size, nil, 0)
        return count
    }

    // MARK: - Dropdown menu

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        clusterHeaderItem = makeInfoItem()
        menu.addItem(clusterHeaderItem)
        menu.addItem(.separator())

        menu.addItem(makeHeaderItem("Top CPU"))
        cpuRowItems = (0 ..< topProcessCount).map { _ in makeInfoItem() }
        cpuRowItems.forEach { menu.addItem($0) }
        menu.addItem(.separator())

        menu.addItem(makeHeaderItem("Top Network  (↓ down  ↑ up)"))
        netRowItems = (0 ..< topProcessCount).map { _ in makeInfoItem() }
        netRowItems.forEach { menu.addItem($0) }
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(doQuit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func makeInfoItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        return item
    }

    private func makeHeaderItem(_ title: String) -> NSMenuItem {
        let item = makeInfoItem()
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: menuFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        return item
    }

    private func setRowTitle(_ item: NSMenuItem, _ text: String) {
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: menuFont,
            .foregroundColor: NSColor.labelColor
        ])
    }

    private func padName(_ name: String, _ width: Int = 24) -> String {
        if name.count >= width {
            return String(name.prefix(width))
        }
        return name.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuGeneration += 1
        let generation = menuGeneration

        setRowTitle(clusterHeaderItem,
                    String(format: "Cores  E %3d%%   P %3d%%", latestECoreUsage, latestPCoreUsage))
        for item in cpuRowItems + netRowItems {
            setRowTitle(item, "measuring…")
        }

        procQueue.async { [weak self] in
            guard let self = self else { return }
            _ = self.procMonitor.topCPUProcesses(0) // establish the baseline
            self.refreshOpenMenu(generation: generation)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuGeneration += 1 // stops the refresh loop
    }

    // Runs on procQueue; reschedules itself (via main, where menuGeneration
    // lives) for as long as the menu stays open.
    private func refreshOpenMenu(generation: Int) {
        let net = ProcMonitor.topNetProcesses(topProcessCount) // blocks ~1s measuring
        let cpu = procMonitor.topCPUProcesses(topProcessCount)

        DispatchQueue.main.async {
            guard generation == self.menuGeneration else { return }

            self.setRowTitle(self.clusterHeaderItem,
                             String(format: "Cores  E %3d%%   P %3d%%",
                                    self.latestECoreUsage, self.latestPCoreUsage))

            for (i, item) in self.cpuRowItems.enumerated() {
                if i < cpu.count {
                    self.setRowTitle(item, String(format: "%@ %6.1f%%",
                                                  self.padName(cpu[i].name), cpu[i].cpuPercent))
                } else {
                    self.setRowTitle(item, "")
                }
            }

            if let net = net {
                for (i, item) in self.netRowItems.enumerated() {
                    if i < net.count {
                        self.setRowTitle(item, String(format: "%@ ↓%@  ↑%@",
                                                      self.padName(net[i].name),
                                                      self.formatNetworkSpeed(net[i].bytesInPerSec),
                                                      self.formatNetworkSpeed(net[i].bytesOutPerSec)))
                    } else {
                        self.setRowTitle(item, "")
                    }
                }
            } else {
                self.setRowTitle(self.netRowItems[0], "nettop unavailable")
                for item in self.netRowItems.dropFirst() {
                    self.setRowTitle(item, "")
                }
            }

            self.procQueue.async {
                self.refreshOpenMenu(generation: generation)
            }
        }
    }

    // MARK: - Status item

    func formatNetworkSpeed(_ bytesPerSecond: UInt64) -> String {
        let kilobytesPerSecond = Double(bytesPerSecond) / 1024.0
        let formattedString: String
        if kilobytesPerSecond >= 1024.0 {
            // Convert to megabytes per second
            let megabytesPerSecond = kilobytesPerSecond / 1024.0
            if megabytesPerSecond >= 100.0 {
                // No decimal places; 100 M
                formattedString = String(format: "%4.0f M", megabytesPerSecond)
            } else if megabytesPerSecond >= 10.0 {
                // One decimal place; 10.0 M
                formattedString = String(format: "%4.1f M", megabytesPerSecond)
            } else {
                // Two decimal places; 1.00 M
                formattedString = String(format: "%4.2f M", megabytesPerSecond)
            }
        } else {
            // Kilobytes per second, no decimals; 100 k
            formattedString = String(format: "%4.0f k", kilobytesPerSecond)
        }
        return formattedString
    }

    private func attributes(forUsage usage: Int) -> [NSAttributedString.Key: Any] {
        if usage < 50 {
            return baseAttributes
        } else if usage < 75 {
            return yellowAttributes
        } else {
            return redAttributes
        }
    }

    // Runs on sampleQueue.
    private func update() {
        guard let cpuLoadInfoPtr = cpuInfo.getCPULoad() else {
            print("Failed to get CPU load info")
            return
        }
        let cpuLoadInfo = cpuLoadInfoPtr.pointee
        let numProcs = Int(cpuLoadInfo.numProcs)
        let eCount = min(eCoreCount, numProcs)

        // Sum ticks per cluster and take one ratio, instead of averaging
        // per-core percentages that were each already rounded.
        var eBusy: UInt64 = 0
        var eTotal: UInt64 = 0
        var pBusy: UInt64 = 0
        var pTotal: UInt64 = 0
        for i in 0 ..< numProcs {
            let load = cpuLoadInfo.loads[i]
            let busy = UInt64(load.busy)
            let total = busy + UInt64(load.idle)
            if i < eCount {
                eBusy += busy
                eTotal += total
            } else {
                pBusy += busy
                pTotal += total
            }
        }
        let eCoreAverageUsage = eTotal > 0 ? Int((Double(eBusy) / Double(eTotal) * 100).rounded()) : 0
        let pCoreAverageUsage = pTotal > 0 ? Int((Double(pBusy) / Double(pTotal) * 100).rounded()) : 0

        // Fetch network stats
        guard let netStatsPtr = netInfo.getInterfaceStats() else {
            print("Failed to get network stats")
            return
        }
        let netStats = netStatsPtr.pointee

        // Format network speeds
        let uploadSpeed = formatNetworkSpeed(netStats.delta_bytes_out)
        let downloadSpeed = formatNetworkSpeed(netStats.delta_bytes_in)

        // Format CPU usage strings
        let eCoreUsageString = String(format: " %3d%%", eCoreAverageUsage)
        let pCoreUsageString = String(format: " %3d%%", pCoreAverageUsage)

        // Combine the attributed strings
        let statusAttrString = NSMutableAttributedString()
        statusAttrString.append(NSAttributedString(string: uploadSpeed, attributes: baseAttributes))
        statusAttrString.append(NSAttributedString(string: eCoreUsageString, attributes: attributes(forUsage: eCoreAverageUsage)))
        statusAttrString.append(NSAttributedString(string: "\n", attributes: baseAttributes))
        statusAttrString.append(NSAttributedString(string: downloadSpeed, attributes: baseAttributes))
        statusAttrString.append(NSAttributedString(string: pCoreUsageString, attributes: attributes(forUsage: pCoreAverageUsage)))

        // Update UI on main thread
        DispatchQueue.main.async {
            self.latestECoreUsage = eCoreAverageUsage
            self.latestPCoreUsage = pCoreAverageUsage
            self.menuItem.button?.attributedTitle = statusAttrString
        }
    }

    @IBAction func doQuit(_ sender: Any?) {
        NSApp.terminate(self)
    }
}
