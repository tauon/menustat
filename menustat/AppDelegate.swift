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
    var menuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let cpuInfo = CPUInfo()
    let netInfo = NetInfo()
    var cpuLoads = [Int]()
    var netBytesDownLast:UInt32 = 0
    var netBytesDownDelta:UInt32 = 0
    var netBytesUpLast:UInt32 = 0
    var netBytesUpDelta:UInt32 = 0
    let cpuLoadString = "%3d%% %3d%% %6d k/s\n%3d%% %3d%% %6d k/s"
    let updateIntervalSeconds:TimeInterval = 1

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        menuItem.button?.font = NSFont(name: "Menlo", size:9)!
        menuItem.action = #selector(AppDelegate.showWindow)

        let t = Timer(
            timeInterval: updateIntervalSeconds,
            target:self,
            selector: #selector(AppDelegate.update),
            userInfo: nil,
            repeats: true)

        RunLoop.current.add(t, forMode: RunLoop.Mode.common)
    }

    @objc func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func update() {
        let cpuLoadInfo = cpuInfo.getCPULoad()
        if cpuLoads.count < 1 {
            cpuLoads = Array(repeating: 0, count: Int(cpuLoadInfo!.pointee.numProcs))
        }
        for i in 0 ..< cpuLoads.count {
            let load = cpuLoadInfo!.pointee.loads[i]
            let busy = load.busy
            let idle = load.idle
            if idle != 0 {
                cpuLoads[i] = Int(round((Double(busy) / ((Double(idle) + Double(busy)) ) * 100)));
            } else {
                cpuLoads[i] = 100
            }
        }
        let netStats = netInfo.getInterfaceStats()
        let bytesIn = netStats!.pointee.delta_bytes_in
        let bytesOut = netStats!.pointee.delta_bytes_out
        self.menuItem.title = String(format: self.cpuLoadString, cpuLoads[0], cpuLoads[1], Int(bytesOut/1024), cpuLoads[2], cpuLoads[3], Int(bytesIn/1024))
        }


    func applicationWillTerminate(aNotification: NSNotification) {
    }

    @IBAction func doQuit(x:NSButton) {
        exit(0)
    }
}

