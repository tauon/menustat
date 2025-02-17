import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    @IBOutlet weak var window: NSWindow!
    @IBOutlet weak var buttonQuit: NSButton?
    @IBOutlet weak var networkInterfaceSelector: NSPopUpButton!
    var menuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let cpuInfo = CPUInfo()
    let netInfo = NetInfo()
    var cpuLoads = [Int]()
    let cpuLoadString = "%3d%% %3d%% %6d k/s\n%3d%% %3d%% %6d k/s"
    let updateIntervalSeconds: TimeInterval = 1
    let fontSize:CGFloat = 8

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Configure the button
        if let button = menuItem.button {
            button.target = self
            button.action = #selector(showWindow)
            button.image = nil // Remove any image if set
            button.title = ""  // Start with an empty title
            button.font = NSFont(name: "Menlo", size: fontSize) // Set initial font size
        }

        // Use scheduledTimer to ensure it runs on the main run loop
        Timer.scheduledTimer(
            timeInterval: updateIntervalSeconds,
            target: self,
            selector: #selector(update),
            userInfo: nil,
            repeats: true)
    }

    @objc func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func update() {
        DispatchQueue.global(qos: .background).async {
            // Fetch CPU load info
            guard let cpuLoadInfo = self.cpuInfo.getCPULoad()?.pointee else {
                print("Failed to get CPU load info")
                return
            }

            // Initialize cpuLoads if necessary
            if self.cpuLoads.count != Int(cpuLoadInfo.numProcs) {
                self.cpuLoads = Array(repeating: 0, count: Int(cpuLoadInfo.numProcs))
            }

            // Process CPU loads
            for i in 0 ..< self.cpuLoads.count {
                let load = cpuLoadInfo.loads[i]
                let busy = load.busy
                let idle = load.idle
                let total = Double(busy + idle)
                if total != 0 {
                    self.cpuLoads[i] = Int(round((Double(busy) / total) * 100))
                } else {
                    self.cpuLoads[i] = 0
                }
            }

            // Fetch network stats
            guard let netStats = self.netInfo.getInterfaceStats()?.pointee else {
                print("Failed to get network stats")
                return
            }
            let bytesIn = netStats.delta_bytes_in
            let bytesOut = netStats.delta_bytes_out

            // Format status text
            let statusText = String(
                format: self.cpuLoadString,
                self.cpuLoads[0],
                self.cpuLoads[1],
                Int(bytesOut / 1024),
                self.cpuLoads[2],
                self.cpuLoads[3],
                Int(bytesIn / 1024)
            )

            // Create attributed string with paragraph style
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byWordWrapping
            paragraphStyle.alignment = .center
            paragraphStyle.lineSpacing = 0 // Adjust line spacing
            paragraphStyle.maximumLineHeight = self.fontSize // Adjust line height

            let attributes: [NSAttributedString.Key: Any] = [
                .paragraphStyle: paragraphStyle
            ]

            let attributedStatusText = NSAttributedString(string: statusText, attributes: attributes)

            // Update the button's attributedTitle on the main thread
            DispatchQueue.main.async {
                self.menuItem.button?.attributedTitle = attributedStatusText
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean up resources if necessary
    }

    @IBAction func doQuit(_ sender: NSButton) {
        NSApp.terminate(self)
    }
}
