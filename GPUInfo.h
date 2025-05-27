#ifndef GPUInfo_h
#define GPUInfo_h

#import <Foundation/Foundation.h>

struct GPUUsage {
    uint64_t gpuCoreUtilization;
    uint64_t gpuMemoryUtilization;
};

@interface GPUInfo : NSObject

- (struct GPUUsage)getGPUUsage;

@end

#endif /* GPUInfo_h */
