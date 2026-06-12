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

    private var clusterRow: MenuRowView!
    private var netTotalsRow: MenuRowView!
    private var cpuRows: [MenuRowView] = []
    private var netRows: [MenuRowView] = []

    // monospacedSystemFont is SF Mono on modern macOS
    private lazy var menuFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    private lazy var paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byCharWrapping
        style.alignment = .left
        style.lineSpacing = -4
        style.maximumLineHeight = fontSize
        style.minimumLineHeight = fontSize
        return style
    }()

    // The centered two-line block draws its glyphs a hair high in the menu
    // bar; a negative baseline offset shifts the drawn text down without
    // changing the layout box the button centers.
    private let statusBaselineOffset: CGFloat = -2

    private lazy var baseAttributes: [NSAttributedString.Key: Any] = [
        .paragraphStyle: paragraphStyle,
        .baselineOffset: statusBaselineOffset,
        .foregroundColor: NSColor.controlTextColor
    ]

    private lazy var yellowAttributes: [NSAttributedString.Key: Any] = [
        .paragraphStyle: paragraphStyle,
        .baselineOffset: statusBaselineOffset,
        .foregroundColor: NSColor.yellow
    ]

    private lazy var redAttributes: [NSAttributedString.Key: Any] = [
        .paragraphStyle: paragraphStyle,
        .baselineOffset: statusBaselineOffset,
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

    // Rows are view-based menu items: the value label is frame-anchored to
    // the right edge (text-layout tricks like tab stops don't survive
    // NSMenu's content sizing), and the view's height sets the exact row
    // height, much tighter than standard menu items.
    private func addRow(to menu: NSMenu, secondary: Bool = false) -> MenuRowView {
        let view = MenuRowView(font: menuFont, secondary: secondary)
        let item = NSMenuItem()
        item.view = view
        menu.addItem(item)
        return view
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        clusterRow = addRow(to: menu)
        netTotalsRow = addRow(to: menu)
        menu.addItem(.separator())

        addRow(to: menu, secondary: true).nameField.stringValue = "Top CPU"
        cpuRows = (0 ..< cpuRowCount).map { _ in addRow(to: menu) }
        menu.addItem(.separator())

        addRow(to: menu, secondary: true).nameField.stringValue = "Top Network  (↓ down  ↑ up)"
        netRows = (0 ..< netRowCount).map { _ in addRow(to: menu) }
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(doQuit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func setRow(_ row: MenuRowView, _ name: String, _ value: String) {
        row.nameField.stringValue = name
        row.valueField.stringValue = value
    }

    // Runs on main.
    private func updateSummaryItems() {
        setRow(clusterRow, "Cores",
               String(format: "E %3d%%   P %3d%%", latestECoreUsage, latestPCoreUsage))
        setRow(netTotalsRow, "Net",
               String(format: "↓%@  ↑%@",
                      formatNetworkSpeed(latestNetDown), formatNetworkSpeed(latestNetUp)))
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true

        updateSummaryItems()
        for rows in [cpuRows, netRows] {
            for (i, row) in rows.enumerated() {
                setRow(row, i == 0 ? "measuring…" : "", "")
            }
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
                for (i, row) in self.cpuRows.enumerated() {
                    if i < cpu.count {
                        self.setRow(row, cpu[i].name, String(format: "%.1f%%", cpu[i].cpuPercent))
                    } else {
                        self.setRow(row, "", "")
                    }
                }
            }

            // nil means the subscription hasn't produced a delta sample yet
            if let net = net {
                for (i, row) in self.netRows.enumerated() {
                    if i < net.count {
                        self.setRow(row, net[i].name,
                                    String(format: "↓%@  ↑%@",
                                           self.formatNetworkSpeed(net[i].bytesInPerSec),
                                           self.formatNetworkSpeed(net[i].bytesOutPerSec)))
                    } else {
                        self.setRow(row, "", "")
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

// One process-list row: name on the left (truncating), value hard-anchored
// to the right edge. The fixed frame keeps the menu width stable from the
// first open and sets a row height tighter than standard menu items.
final class MenuRowView: NSView {

    static let rowWidth: CGFloat = 340
    static let rowHeight: CGFloat = 15
    static let sideInset: CGFloat = 14
    static let nameWidth: CGFloat = 180

    let nameField: NSTextField
    let valueField: NSTextField

    init(font: NSFont, secondary: Bool = false) {
        let textHeight = ceil(font.ascender - font.descender + font.leading)
        let textY = (Self.rowHeight - textHeight) / 2

        nameField = NSTextField(labelWithString: "")
        nameField.frame = NSRect(x: Self.sideInset, y: textY,
                                 width: Self.nameWidth, height: textHeight)
        nameField.lineBreakMode = .byTruncatingTail

        let valueX = Self.sideInset + Self.nameWidth
        valueField = NSTextField(labelWithString: "")
        valueField.frame = NSRect(x: valueX, y: textY,
                                  width: Self.rowWidth - valueX - Self.sideInset,
                                  height: textHeight)
        valueField.alignment = .right
        valueField.lineBreakMode = .byClipping

        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: Self.rowHeight))

        for field in [nameField, valueField] {
            field.font = font
            field.textColor = secondary ? .secondaryLabelColor : .labelColor
            addSubview(field)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
