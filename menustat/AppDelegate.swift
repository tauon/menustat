import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    @IBOutlet weak var window: NSWindow!
    @IBOutlet weak var buttonQuit: NSButton?
    @IBOutlet weak var networkInterfaceSelector: NSPopUpButton!
    var menuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let statusBarView = StatusBarView()
    let cpuInfo = CPUInfo()
    let netInfo = NetInfo()
    var cpuLoads = [Int]()
    let cpuLoadString = "%3d%% %3d%% %6d k/s\n%3d%% %3d%% %6d k/s"
    let updateIntervalSeconds: TimeInterval = 1

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Set the custom view as the status item's view
        menuItem.view = statusBarView

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

            // Update the UI on the main thread
            DispatchQueue.main.async {
                self.statusBarView.statusText = statusText
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
