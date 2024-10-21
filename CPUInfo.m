#import "CPUInfo.h"

@implementation CPUInfo

- (instancetype)init {
    self = [super init];
    if (self) {
        loads = NULL;
        lastLoads = NULL;
    }
    return self;
}

- (void)dealloc {
    if (loads) {
        if (loads->loads) {
            free(loads->loads);
        }
        free(loads);
    }
    if (lastLoads) {
        free(lastLoads);
    }
    // ARC handles [super dealloc]
}

- (struct CPULoads*)getCPULoadInfo {
    natural_t numCPUs;
    kern_return_t kr;
    processor_info_array_t cpuInfo;
    mach_msg_type_number_t numCpuInfo;

    kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCpuInfo);
    if (kr != KERN_SUCCESS) {
        return NULL;
    }

    if (!loads) {
        loads = malloc(sizeof(struct CPULoads));
        loads->loads = malloc(sizeof(struct CPULoad) * numCPUs);
        loads->numProcs = numCPUs;
    }

    if (!lastLoads) {
        lastLoads = malloc(sizeof(struct CPULoad) * numCPUs);
        memset(lastLoads, 0, sizeof(struct CPULoad) * numCPUs);
    }

    for (unsigned int i = 0; i < numCPUs; ++i) {
        uint32_t user = cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_USER];
        uint32_t system = cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_SYSTEM];
        uint32_t idle = cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_IDLE];
        uint32_t nice = cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_NICE];

        uint32_t totalTicks = user + system + idle + nice;
        uint32_t busyTicks = totalTicks - idle;

        if (totalTicks != 0) {
            loads->loads[i].busy = busyTicks - lastLoads[i].busy;
            loads->loads[i].idle = idle - lastLoads[i].idle;
        } else {
            loads->loads[i].busy = 0;
            loads->loads[i].idle = 0;
        }

        lastLoads[i].busy = busyTicks;
        lastLoads[i].idle = idle;
    }

    kr = vm_deallocate(mach_task_self(), (vm_address_t)cpuInfo, numCpuInfo * sizeof(integer_t));
    if (kr != KERN_SUCCESS) {
        // uh oh
    }

    return loads;
}

@end
