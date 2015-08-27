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
    var menuItem = NSStatusBar.systemStatusBar().statusItemWithLength(NSVariableStatusItemLength)
    let cpuInfo = CPUInfo()
    let netInfo = NetInfo()
    var netBytesLast:UInt32 = 0
    var netBytesDelta:UInt32 = 0
    let cpuLoadString = "% 2d%% % 2d%% % 2d%% % 2d%% % 7.1fk"
    let updateIntervalSeconds:NSTimeInterval = 2
    
    func applicationDidFinishLaunching(aNotification: NSNotification) {
        menuItem.button?.font = NSFont(name: "Menlo", size:9)!
        menuItem.action = "showWindow"
        let t = NSTimer(
            timeInterval: updateIntervalSeconds,
            target:self,
            selector: Selector("update"),
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
        for var i = 0; i < numCores; i++ {
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
        let now = (s["en0"]?.totalin)!
        if netBytesLast != 0 {
            netBytesDelta = now - netBytesLast
        }
        netBytesLast = now
        let netKiloBytesPerSecond:Double = (Double(netBytesDelta) / 1000) / updateIntervalSeconds
        menuItem.title = NSString(format: cpuLoadString, cpuLoads[0], cpuLoads[1], cpuLoads[2], cpuLoads[3], netKiloBytesPerSecond) as String
    }

    func applicationWillTerminate(aNotification: NSNotification) {
    }
    
    @IBAction func doQuit(x:NSButton) {
        NSApplication.sharedApplication().terminate(self)
    }


}

