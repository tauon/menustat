//
//  CPUInfo.m
//  menustat
//
//  Created by jeff on 6/10/15.

#import "CPUInfo.h"

@implementation CPUInfo

processor_info_array_t loadInfo;
mach_msg_type_number_t sizeLoadInfo;
struct Load* lastLoads;
struct LoadDeltas* loadDeltas;

- (struct LoadDeltas*)getLoad {

    natural_t numCores = 0U;
    kern_return_t err =
        host_processor_info(
                            mach_host_self(),
                            PROCESSOR_CPU_LOAD_INFO,
                            &numCores,
                            &loadInfo,
                            &sizeLoadInfo);
    if(err != KERN_SUCCESS) {
        return NULL;
    }
    if(!loadDeltas) {
        loadDeltas = malloc(sizeof(struct LoadDeltas));
        loadDeltas->loads = malloc(sizeof(struct Load) * numCores);
        loadDeltas->numCores = numCores;
    }
    for(unsigned i = 0U; i < numCores; ++i) {
        integer_t busy, idle = 0;
        unsigned coreOffset = CPU_STATE_MAX * i;
        busy = loadInfo[coreOffset + CPU_STATE_USER];
        busy += loadInfo[coreOffset + CPU_STATE_SYSTEM];
        busy += loadInfo[coreOffset + CPU_STATE_NICE];
        idle = loadInfo[coreOffset + CPU_STATE_IDLE];
        if(!lastLoads) {
            lastLoads = malloc(sizeof(struct Load) * numCores);
            lastLoads[i].busy = busy;
            lastLoads[i].idle = idle;
        }
        loadDeltas->loads[i].busy = busy - lastLoads[i].busy;
        loadDeltas->loads[i].idle = idle - lastLoads[i].idle;
        lastLoads[i].busy = busy;
        lastLoads[i].idle = idle;
    }
        size_t prevCpuInfoSize = sizeof(integer_t) * numCores;
        vm_deallocate(mach_task_self(), (vm_address_t)loadInfo, prevCpuInfoSize);
    loadInfo = NULL;
    return loadDeltas;
}

@end