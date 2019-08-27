//
//  CPUInfo.h
//  menustat
//
//  Created by jeff on 6/10/15.

#ifndef CPUInfo_h
#define CPUInfo_h

#import <Foundation/Foundation.h>
#include <mach/vm_map.h>
#include <mach/mach_host.h>

@interface CPUInfo : NSObject

struct CPULoad {
    uint idle;
    uint busy;
};

struct CPULoads {
    struct CPULoad* loads;
    uint numProcs;
};

- (struct CPULoads*)getCPULoadInfo;

@end

#endif /* CPUInfo_h */
