//
//  CPUInfo.swift
//  menustat
//
//  Created by jeff on 6/15/15.

import Foundation

struct Load {
    var busy:Int32
    var idle:Int32
}

let CPU_STATE_USER   = 0
let CPU_STATE_SYSTEM = 1
let CPU_STATE_IDLE   = 2
let CPU_STATE_NICE   = 3
let CPU_STATE_MAX    = 4

class CPUInfo2 {
    var numCPUs = natural_t()
    var cpuStateInfo = processor_info_array_t(nil)
    var infoCount = mach_msg_type_number_t()
    var currentLoad:[Load]?
    var previousLoad:[Load]?

    func getLoad() -> [Load]? {
        let ret = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuStateInfo,
            &infoCount)
        if(ret != KERN_SUCCESS) {
            return nil
        }
        if currentLoad == nil {
            currentLoad = [Load](count: Int(numCPUs), repeatedValue: Load(busy: 0, idle: 0))
            previousLoad = [Load](count: Int(numCPUs), repeatedValue: Load(busy: 0, idle: 0))
        }
        for i in 0 ..< Int(numCPUs) {
            var load = Load(busy: 0, idle: 0)
            let coreIndexOffset = CPU_STATE_MAX * i
            load.busy += cpuStateInfo[coreIndexOffset + CPU_STATE_USER]
            load.busy += cpuStateInfo[coreIndexOffset + CPU_STATE_SYSTEM]
            load.busy += cpuStateInfo[coreIndexOffset + CPU_STATE_NICE]
            load.busy -= previousLoad![i].busy
            load.idle = cpuStateInfo[coreIndexOffset + CPU_STATE_IDLE] - previousLoad![i].idle
            currentLoad![i] = load
        }
        let cpuStatePtr = UnsafePointer<vm_address_t>(cpuStateInfo)
        vm_deallocate(
            mach_task_self_ as vm_map_t,
            cpuStatePtr.memory as vm_address_t,
            vm_size_t(sizeof(integer_t) * Int(infoCount)))
        previousLoad = currentLoad
        return currentLoad
    }
}
