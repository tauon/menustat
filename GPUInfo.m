#import "GPUInfo.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/graphics/IOAccelTypes.h>
// Add the printStats function here, before @implementation
static void printStats(const typeof(struct {
    uint32_t version;
    uint32_t revision;
    uint64_t task_gpu_utilisation;
    uint64_t task_gpu_time;
    uint64_t task_cpu_utilisation;
    uint64_t task_cpu_time;
    uint64_t task_io_utilisation;
    uint64_t task_io_time;
}) *stats) {
    NSLog(@"Stats:");
    NSLog(@"  Version: %u", stats->version);
    NSLog(@"  Revision: %u", stats->revision);
    NSLog(@"  GPU Utilisation: %llu", stats->task_gpu_utilisation);
    NSLog(@"  GPU Time: %llu", stats->task_gpu_time);
    NSLog(@"  CPU Utilisation: %llu", stats->task_cpu_utilisation);
    NSLog(@"  CPU Time: %llu", stats->task_cpu_time);
    NSLog(@"  IO Utilisation: %llu", stats->task_io_utilisation);
    NSLog(@"  IO Time: %llu", stats->task_io_time);
}

@implementation GPUInfo

- (struct GPUUsage)getGPUUsage {
    struct GPUUsage gpuUsage = {0, 0};
    
    io_iterator_t iterator;
    kern_return_t result = IOServiceGetMatchingServices(kIOMasterPortDefault,
                                                        IOServiceMatching("IOAccelerator"),
                                                        &iterator);
    if (result != KERN_SUCCESS) {
        NSLog(@"Failed to get stats: %d", result);
        return gpuUsage;
    }
    
    io_object_t service;
    while ((service = IOIteratorNext(iterator))) {
        io_connect_t connect;
        result = IOServiceOpen(service, mach_task_self(), 0, &connect);
        if (result != KERN_SUCCESS) {
            NSLog(@"Failed to open IOService: %d (%s)", result, mach_error_string(result));
            IOObjectRelease(service);
            continue;
        }
        
        // Define the statistics structure
        struct {
            uint32_t version;
            uint32_t revision;
            uint64_t task_gpu_utilisation;
            uint64_t task_gpu_time;
            uint64_t task_cpu_utilisation;
            uint64_t task_cpu_time;
            uint64_t task_io_utilisation;
            uint64_t task_io_time;
        } stats;
        
        size_t statsSize = sizeof(stats);
        uint32_t outputCount = 0;
        
        result = IOConnectCallStructMethod(connect, 0 /* method index */, NULL, 0, &stats, &statsSize);
        if (result == KERN_SUCCESS) {
            NSLog(@"asdasd");
            // Assuming stats.task_gpu_utilisation gives you GPU utilization percentage
            gpuUsage.gpuCoreUtilization = stats.task_gpu_utilisation;
            // Print the stats
             printStats(&stats);
            // Add any other stats you want to track
        } else {
            NSLog(@"Failed to get stats: %d", result);
        }
        
        IOServiceClose(connect);
        IOObjectRelease(service);
        break; // Only need the first GPU
    }
    IOObjectRelease(iterator);
    return gpuUsage;
}

@end
