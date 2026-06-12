#import "CPUInfo.h"

@implementation CPUInfo

- (instancetype)init {
    self = [super init];
    if (self) {
        loads = NULL;
        lastLoads = NULL;
        // mach_host_self() allocates a new send right on every call; fetch it
        // once so repeated sampling doesn't leak a port reference per call.
        host = mach_host_self();
    }
    return self;
}

- (void)dealloc {
    if (loads) {
        free(loads->loads);
        free(loads);
        loads = NULL;
    }
    free(lastLoads);
    lastLoads = NULL;
    if (host != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), host);
        host = MACH_PORT_NULL;
    }
}

- (struct CPULoads*)getCPULoadInfo {
    natural_t numCPUs;
    kern_return_t kr;
    processor_info_array_t cpuInfo;
    mach_msg_type_number_t numCpuInfo;

    kr = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCpuInfo);
    if (kr != KERN_SUCCESS) {
        return NULL;
    }

    if (!loads || loads->numProcs != numCPUs) {
        if (!loads) {
            loads = calloc(1, sizeof(struct CPULoads));
            if (!loads) {
                goto fail;
            }
        }
        struct CPULoad *newLoads = realloc(loads->loads, sizeof(struct CPULoad) * numCPUs);
        if (!newLoads) {
            goto fail;
        }
        loads->loads = newLoads;
        struct CPULoad *newLast = realloc(lastLoads, sizeof(struct CPULoad) * numCPUs);
        if (!newLast) {
            goto fail;
        }
        lastLoads = newLast;
        // No baseline for the new CPU set; the first sample after a change
        // reports the average since boot and self-corrects on the next one.
        memset(lastLoads, 0, sizeof(struct CPULoad) * numCPUs);
        loads->numProcs = numCPUs;
    }

    for (natural_t i = 0; i < numCPUs; ++i) {
        natural_t base = CPU_STATE_MAX * i;
        uint32_t user = cpuInfo[base + CPU_STATE_USER];
        uint32_t system = cpuInfo[base + CPU_STATE_SYSTEM];
        uint32_t idle = cpuInfo[base + CPU_STATE_IDLE];
        uint32_t nice = cpuInfo[base + CPU_STATE_NICE];
        uint32_t busyTicks = user + system + nice;

        // Unsigned subtraction stays correct across uint32 tick wraparound.
        loads->loads[i].busy = busyTicks - lastLoads[i].busy;
        loads->loads[i].idle = idle - lastLoads[i].idle;

        lastLoads[i].busy = busyTicks;
        lastLoads[i].idle = idle;
    }

    vm_deallocate(mach_task_self(), (vm_address_t)cpuInfo, numCpuInfo * sizeof(integer_t));
    return loads;

fail:
    vm_deallocate(mach_task_self(), (vm_address_t)cpuInfo, numCpuInfo * sizeof(integer_t));
    return NULL;
}

@end
