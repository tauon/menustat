//
//  AppDelegate.swift
//  menustat
//
//  Created by jeff on 6/10/15.

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    @IBOutlet weak var window: NSWindow!
    @IBOutlet weak var buttonQuit: NSButton?
    @IBOutlet weak var networkInterfaceSelector: NSPopUpButton!
    var menuItem = NSStatusBar.systemStatusBar().statusItemWithLength(NSVariableStatusItemLength)
    let cpuInfo = CPUInfo()
    let netInfo = NetInfo()
    var netBytesDownLast:UInt32 = 0
    var netBytesDownDelta:UInt32 = 0
    var netBytesUpLast:UInt32 = 0
    var netBytesUpDelta:UInt32 = 0
    let cpuLoadString = "%3d%% %3d%% %6.1fk\n%3d%% %3d%% %6.1fk"
    let updateIntervalSeconds:NSTimeInterval = 2
    var interfaces:[String] = []
    var selectedNetworkInterface = "en0"

    func applicationDidFinishLaunching(aNotification: NSNotification) {
        menuItem.button?.font = NSFont(name: "Menlo", size:9)!
        menuItem.action = #selector(AppDelegate.showWindow)
        let interfaceStats = netInfo.getInterfaceStats()
        for (iface, _) in interfaceStats {
            interfaces.append(iface)
        }
        networkInterfaceSelector.addItemsWithTitles(interfaces)

        let t = NSTimer(
            timeInterval: updateIntervalSeconds,
            target:self,
            selector: #selector(AppDelegate.update),
            userInfo: nil,
            repeats: true)
        NSRunLoop.currentRunLoop().addTimer(t, forMode: NSRunLoopCommonModes)
    }

    func showWindow() {
        NSApp.activateIgnoringOtherApps(true)
        window.makeKeyAndOrderFront(nil)
    }

    func update() {
        let loadDeltas = cpuInfo.getLoad()
        let numCores = Int(loadDeltas.memory.numCores)
        var cpuLoads = [Int](count: numCores, repeatedValue: 0)
        for i in 0 ..< numCores {
            let load = loadDeltas.memory.loads[i]
            let busy = load.busy
            let idle = load.idle
            if idle != 0 {
                cpuLoads[i] = Int(round((Double(busy) / ((Double(idle) + Double(busy)) ) * 100)));
            } else {
                cpuLoads[i] = 100
            }
        }
        let s = netInfo.getInterfaceStats()
        let totalDownNow = (s[selectedNetworkInterface]?.totalin)!
        if netBytesDownLast != 0 {
            netBytesDownDelta = totalDownNow - netBytesDownLast
        }
        netBytesDownLast = totalDownNow
        let totalUpNow = (s[selectedNetworkInterface]?.totalout)!
        if netBytesUpLast != 0 {
            netBytesUpDelta = totalUpNow - netBytesUpLast
        }
        netBytesUpLast = totalUpNow
        let netDownKiloBytesPerSecond:Double = (Double(netBytesDownDelta) / 1000) / updateIntervalSeconds
        let netUpKiloBytesPerSecond:Double = (Double(netBytesUpDelta) / 1000) / updateIntervalSeconds
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)) {
            dispatch_async(dispatch_get_main_queue()) {
self.menuItem.title = NSString(format: self.cpuLoadString, cpuLoads[0], cpuLoads[1], netUpKiloBytesPerSecond, cpuLoads[2], cpuLoads[3], netDownKiloBytesPerSecond) as String
            }
        }

    }

    func applicationWillTerminate(aNotification: NSNotification) {
    }

    @IBAction func doQuit(x:NSButton) {
        NSApplication.sharedApplication().terminate(self)
    }

    @IBAction func doSelectNetworkInterface(x:NSPopUpButton) {
        selectedNetworkInterface = x.titleOfSelectedItem!
        netBytesDownLast = 0
        netBytesUpLast = 0
    }
}

