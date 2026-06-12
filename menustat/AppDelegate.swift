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
    let cpuRowCount = 10
    let netRowCount = 5

    // CPUInfo and NetInfo keep mutable state between samples, so all sampling
    // runs on this single serial queue.
    private let sampleQueue = DispatchQueue(label: "menustat.sample", qos: .utility)
    private var updateTimer: DispatchSourceTimer?

    // Per-process sampling only runs while the dropdown is open. ProcMonitor
    // state is confined to this queue; it's .userInitiated because the user
    // is actively looking at the menu.
    private let procQueue = DispatchQueue(label: "menustat.proc", qos: .userInitiated)
    private let procMonitor = ProcMonitor()
    private var menuIsOpen = false
    private var menuRefreshTimer: DispatchSourceTimer?

    // Kernel flow subscription (NetworkStatistics). The first query after
    // subscribing only establishes baselines, so it stays warm for a while
    // after the menu closes and reopening shows data immediately.
    private var netProcStats: NetProcStats?
    private var netStatsShutdownWork: DispatchWorkItem?
    private let netStatsKeepWarmSeconds: TimeInterval = 30

    // Latest totals from the status item, written and read on the main queue.
    private var latestECoreUsage = 0
    private var latestPCoreUsage = 0
    private var latestNetDown: UInt64 = 0
    private var latestNetUp: UInt64 = 0

    private var clusterHeaderItem: NSMenuItem!
    private var netTotalsItem: NSMenuItem!
    private var cpuRowItems: [NSMenuItem] = []
    private var netRowItems: [NSMenuItem] = []

    // monospacedSystemFont is SF Mono on modern macOS
    private lazy var menuFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    // Right-aligned tab stops give the number columns a hard right edge
    // (more robust than space-padding), and the capped line height tightens
    // the row spacing of the process lists.
    private lazy var menuRowParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.tabStops = [
            NSTextTab(textAlignment: .right, location: 220, options: [:]),
            NSTextTab(textAlignment: .right, location: 300, options: [:])
        ]
        style.lineBreakMode = .byClipping
        style.minimumLineHeight = 12
        style.maximumLineHeight = 12
        return style
    }()

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
            button.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
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
        netTotalsItem = makeInfoItem()
        menu.addItem(netTotalsItem)
        menu.addItem(.separator())

        menu.addItem(makeHeaderItem("Top CPU"))
        cpuRowItems = (0 ..< cpuRowCount).map { _ in makeInfoItem() }
        cpuRowItems.forEach { menu.addItem($0) }
        menu.addItem(.separator())

        menu.addItem(makeHeaderItem("Top Network  (↓ down  ↑ up)"))
        netRowItems = (0 ..< netRowCount).map { _ in makeInfoItem() }
        netRowItems.forEach { menu.addItem($0) }
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(doQuit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // Info rows stay enabled: disabled menu items dim their attributed
    // titles, which made the text hard to read.
    private func makeInfoItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = true
        return item
    }

    private func makeHeaderItem(_ title: String) -> NSMenuItem {
        let item = makeInfoItem()
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: menuFont,
            .paragraphStyle: menuRowParagraphStyle,
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        return item
    }

    private func setRowTitle(_ item: NSMenuItem, _ text: String) {
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: menuFont,
            .paragraphStyle: menuRowParagraphStyle,
            .foregroundColor: NSColor.labelColor
        ])
    }

    private func truncateName(_ name: String, _ width: Int = 24) -> String {
        return name.count > width ? String(name.prefix(width)) : name
    }

    // Runs on main.
    private func updateSummaryItems() {
        setRowTitle(clusterHeaderItem,
                    String(format: "Cores  E %3d%%   P %3d%%", latestECoreUsage, latestPCoreUsage))
        setRowTitle(netTotalsItem,
                    String(format: "Net    ↓%@  ↑%@",
                           formatNetworkSpeed(latestNetDown), formatNetworkSpeed(latestNetUp)))
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true

        updateSummaryItems()
        for item in cpuRowItems + netRowItems {
            setRowTitle(item, "measuring…")
        }

        netStatsShutdownWork?.cancel()
        netStatsShutdownWork = nil
        if netProcStats == nil {
            let stats = NetProcStats(queue: procQueue)
            netProcStats = stats
            procQueue.async {
                stats.start()
            }
        }

        // The first fire is immediate: with a warm stream and a CPU baseline
        // from a previous open, the menu fills in right away.
        let timer = DispatchSource.makeTimerSource(queue: procQueue)
        timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.refreshOpenMenu()
        }
        timer.resume()
        menuRefreshTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        menuRefreshTimer?.cancel()
        menuRefreshTimer = nil

        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.menuIsOpen else { return }
            if let stats = self.netProcStats {
                self.procQueue.async {
                    stats.stop()
                }
            }
            self.netProcStats = nil
            self.netStatsShutdownWork = nil
        }
        netStatsShutdownWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + netStatsKeepWarmSeconds, execute: work)
    }

    // Runs on procQueue once a second while the menu is open.
    private func refreshOpenMenu() {
        let cpu = procMonitor.topCPUProcesses(cpuRowCount)
        guard let stats = netProcStats else {
            applyMenuUpdate(cpu: cpu, net: nil)
            return
        }
        stats.queryRates { [weak self] rows in
            // runs on procQueue
            self?.applyMenuUpdate(cpu: cpu, net: rows)
        }
    }

    private func applyMenuUpdate(cpu: [ProcCPUUsage], net: [NetProcRow]?) {
        DispatchQueue.main.async {
            guard self.menuIsOpen else { return }

            self.updateSummaryItems()

            // empty means no baseline yet (first sample); keep "measuring…"
            if !cpu.isEmpty {
                for (i, item) in self.cpuRowItems.enumerated() {
                    if i < cpu.count {
                        self.setRowTitle(item, String(format: "%@\t%.1f%%",
                                                      self.truncateName(cpu[i].name), cpu[i].cpuPercent))
                    } else {
                        self.setRowTitle(item, "")
                    }
                }
            }

            // nil means the subscription hasn't produced a delta sample yet
            if let net = net {
                for (i, item) in self.netRowItems.enumerated() {
                    if i < net.count {
                        self.setRowTitle(item, String(format: "%@\t↓%@\t↑%@",
                                                      self.truncateName(net[i].name),
                                                      self.formatNetworkSpeed(net[i].bytesInPerSec),
                                                      self.formatNetworkSpeed(net[i].bytesOutPerSec)))
                    } else {
                        self.setRowTitle(item, "")
                    }
                }
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
            self.latestNetDown = netStats.delta_bytes_in
            self.latestNetUp = netStats.delta_bytes_out
            self.menuItem.button?.attributedTitle = statusAttrString
        }
    }

    @IBAction func doQuit(_ sender: Any?) {
        NSApp.terminate(self)
    }
}
