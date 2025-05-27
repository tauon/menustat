import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    @IBOutlet weak var window: NSWindow!
    var menuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let cpuInfo = CPUInfo()
    let netInfo = NetInfo()
    var cpuLoads = [Int]()
    var eCoreCount = 0
    var pCoreCount = 0
    let updateIntervalSeconds: TimeInterval = 1
    let fontSize: CGFloat = 8

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Get core counts
        let coreCounts = getCoreCounts()
        eCoreCount = coreCounts.eCoreCount
        pCoreCount = coreCounts.pCoreCount

        // Configure the button
        if let button = menuItem.button {
            button.target = self
            button.action = #selector(showWindow)
            button.image = nil
            button.title = ""
            button.font = NSFont(name: "Menlo", size: fontSize)
        }

        // Set up the timer
        Timer.scheduledTimer(
            timeInterval: updateIntervalSeconds,
            target: self,
            selector: #selector(update),
            userInfo: nil,
            repeats: true)
    }

    func getCoreCounts() -> (eCoreCount: Int, pCoreCount: Int) {
        var eCoreCount: Int = 0
        var pCoreCount: Int = 0
        var size = MemoryLayout<Int>.size

        sysctlbyname("hw.perflevel0.physicalcpu", &eCoreCount, &size, nil, 0)
        sysctlbyname("hw.perflevel1.physicalcpu", &pCoreCount, &size, nil, 0)

        return (eCoreCount, pCoreCount)
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

    @objc func update() {
        DispatchQueue.global(qos: .background).async {
            // Fetch CPU load info
            guard let cpuLoadInfoPtr = self.cpuInfo.getCPULoad() else {
                print("Failed to get CPU load info")
                return
            }
            let cpuLoadInfo = cpuLoadInfoPtr.pointee

            // Initialize cpuLoads if necessary
            if self.cpuLoads.count != Int(cpuLoadInfo.numProcs) {
                self.cpuLoads = Array(repeating: 0, count: Int(cpuLoadInfo.numProcs))
            }

            var eCoreTotalUsage = 0
            var pCoreTotalUsage = 0

            // Process CPU loads
            for i in 0 ..< self.cpuLoads.count {
                let load = cpuLoadInfo.loads[i]
                let busy = load.busy
                let idle = load.idle
                let total = Double(busy + idle)
                let usage: Int
                if total != 0 {
                    usage = Int(round((Double(busy) / total) * 100))
                } else {
                    usage = 0
                }
                self.cpuLoads[i] = usage

                // Map cores to efficiency and performance cores
                if i < self.eCoreCount {
                    eCoreTotalUsage += usage
                } else {
                    pCoreTotalUsage += usage
                }
            }

            // Calculate average usage
            let eCoreAverageUsage = self.eCoreCount > 0 ? eCoreTotalUsage / self.eCoreCount : 0
            let pCoreAverageUsage = self.pCoreCount > 0 ? pCoreTotalUsage / self.pCoreCount : 0

            // Fetch network stats
            guard let netStatsPtr = self.netInfo.getInterfaceStats() else {
                print("Failed to get network stats")
                return
            }
            let netStats = netStatsPtr.pointee
            let bytesIn = netStats.delta_bytes_in
            let bytesOut = netStats.delta_bytes_out

            // Format network speeds
            let uploadSpeed = self.formatNetworkSpeed(bytesOut)
            let downloadSpeed = self.formatNetworkSpeed(bytesIn)

            // Format CPU usage strings
            let eCoreUsageString = String(format: " %3d%%", eCoreAverageUsage)
            let pCoreUsageString = String(format: " %3d%%", pCoreAverageUsage)

            // Prepare attributes
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byCharWrapping
            paragraphStyle.alignment = .left
            paragraphStyle.lineSpacing = -4
            paragraphStyle.maximumLineHeight = self.fontSize
            paragraphStyle.minimumLineHeight = self.fontSize

            // Base attributes for normal text
            let baseAttributes: [NSAttributedString.Key: Any] = [
                .paragraphStyle: paragraphStyle,
                .foregroundColor: NSColor.controlTextColor // Default text color
            ]
            
            // Attributes for yellow text
            let yellowAttributes: [NSAttributedString.Key: Any] = [
                .paragraphStyle: paragraphStyle,
                .foregroundColor: NSColor.yellow
            ]

            // Attributes for red text
            let redAttributes: [NSAttributedString.Key: Any] = [
                .paragraphStyle: paragraphStyle,
                .foregroundColor: NSColor.red
            ]

            // Create attributed strings
            let uploadSpeedAttr = NSAttributedString(string: uploadSpeed, attributes: baseAttributes)
            let downloadSpeedAttr = NSAttributedString(string: downloadSpeed, attributes: baseAttributes)

            // Decide which attributes to use for CPU usage based on the percentage
            var eCoreAttributes = baseAttributes
            var pCoreAttributes = baseAttributes
            
            if eCoreAverageUsage < 50 {
                eCoreAttributes = baseAttributes
            } else if eCoreAverageUsage < 75 {
                eCoreAttributes = yellowAttributes
            } else {
                eCoreAttributes = redAttributes
            }
            
            if pCoreAverageUsage < 50 {
                pCoreAttributes = baseAttributes
            } else if pCoreAverageUsage < 75 {
                pCoreAttributes = yellowAttributes
            } else {
                pCoreAttributes = redAttributes
            }

            let eCoreUsageAttr = NSAttributedString(string: eCoreUsageString, attributes: eCoreAttributes)
            let pCoreUsageAttr = NSAttributedString(string: pCoreUsageString, attributes: pCoreAttributes)

            // Create newlines
            let newline = NSAttributedString(string: "\n", attributes: baseAttributes)

            // Combine the attributed strings
            let statusAttrString = NSMutableAttributedString()
//            statusAttrString.append(eCoreUsageAttr)
//            statusAttrString.append(uploadSpeedAttr)
//            statusAttrString.append(newline)
//            statusAttrString.append(pCoreUsageAttr)
//            statusAttrString.append(downloadSpeedAttr)

            statusAttrString.append(uploadSpeedAttr)
            statusAttrString.append(eCoreUsageAttr)
            statusAttrString.append(newline)
            
            statusAttrString.append(downloadSpeedAttr)
            statusAttrString.append(pCoreUsageAttr)
            

            // Update UI on main thread
            DispatchQueue.main.async {
                self.menuItem.button?.attributedTitle = statusAttrString
            }
        }
    }

    @IBAction func doQuit(_ sender: Any?) {
        NSApp.terminate(self)
    }
}
