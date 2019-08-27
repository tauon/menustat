//
//  CPUInfo.m
//  menustat
//
//  Created by jeff on 6/10/15.

#import "CPUInfo.h"

@implementation CPUInfo

processor_info_array_t processorInfo;
mach_msg_type_number_t sizeProcessorLoadInfo;
struct CPULoad* lastLoads;
struct CPULoads* loads;
uint numProcs;

- (struct CPULoads*) getCPULoadInfo {
    numProcs = 0;
    kern_return_t err =
        host_processor_info(
                            mach_host_self(),
                            PROCESSOR_CPU_LOAD_INFO,
                            &numProcs,
                            &processorInfo,
                            &sizeProcessorLoadInfo);
    if(err != KERN_SUCCESS) {
        return NULL;
    }
    if(!loads) {
        loads = malloc(sizeof(struct CPULoads));
        loads->loads = malloc(sizeof(struct CPULoad) * numProcs);
        loads->numProcs = numProcs;
    }
    for(uint i = 0; i < numProcs; ++i) {
        uint totalBusyTicks, totalIdleTicks = 0;
        uint cpuStateOffset = CPU_STATE_MAX * i;
        totalBusyTicks = processorInfo[cpuStateOffset + CPU_STATE_USER];
        totalBusyTicks += processorInfo[cpuStateOffset + CPU_STATE_SYSTEM];
        totalBusyTicks += processorInfo[cpuStateOffset + CPU_STATE_NICE];
        totalIdleTicks = processorInfo[cpuStateOffset + CPU_STATE_IDLE];
        if(!lastLoads) {
            lastLoads = malloc(sizeof(struct CPULoad) * numProcs);
            lastLoads[i].busy = totalBusyTicks;
            lastLoads[i].idle = totalIdleTicks;
        }
        loads->loads[i].busy = totalBusyTicks - lastLoads[i].busy;
        loads->loads[i].idle = totalIdleTicks - lastLoads[i].idle;
        lastLoads[i].busy = totalBusyTicks;
        lastLoads[i].idle = totalIdleTicks;
    }
        size_t prevCpuInfoSize = sizeof(integer_t) * numProcs;
        vm_deallocate(mach_task_self(), (vm_address_t)processorInfo, prevCpuInfoSize);
        processorInfo = NULL;
        return loads;
}

@end
