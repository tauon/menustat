import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    @IBOutlet weak var window: NSWindow!
    var menuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let cpuInfo = CPUInfo()
    let netInfo = NetInfo()
    var eCoreCount = 0
    let updateIntervalSeconds: TimeInterval = 1
    let fontSize: CGFloat = 8

    // CPUInfo and NetInfo keep mutable state between samples, so all sampling
    // runs on this single serial queue.
    private let sampleQueue = DispatchQueue(label: "menustat.sample", qos: .utility)
    private var updateTimer: DispatchSourceTimer?

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

        // Configure the button
        if let button = menuItem.button {
            button.target = self
            button.action = #selector(showWindow)
            button.image = nil
            button.title = ""
            button.font = NSFont(name: "Menlo", size: fontSize)
        }

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

    @objc func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

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
            self.menuItem.button?.attributedTitle = statusAttrString
        }
    }

    @IBAction func doQuit(_ sender: Any?) {
        NSApp.terminate(self)
    }
}
