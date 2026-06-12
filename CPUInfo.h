#ifndef CPUInfo_h
#define CPUInfo_h

#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <mach/processor_info.h>
#include <mach/mach_host.h>

struct CPULoad {
    uint idle;
    uint busy;
};

struct CPULoads {
    struct CPULoad* loads;
    uint numProcs;
};

// Not thread-safe: call getCPULoadInfo from a single serial queue.
@interface CPUInfo : NSObject {
    struct CPULoads* loads;
    struct CPULoad* lastLoads;
    host_t host;
}

- (struct CPULoads*)getCPULoadInfo;

@end

#endif /* CPUInfo_h */
