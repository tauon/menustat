#ifndef NetInfo_h
#define NetInfo_h

#import <Foundation/Foundation.h>

typedef struct net_info {
    UInt64 total_bytes_in;
    UInt64 total_bytes_out;
    UInt64 delta_bytes_in;   // bytes per second, normalized by actual elapsed time
    UInt64 delta_bytes_out;  // bytes per second, normalized by actual elapsed time
} net_info;

typedef struct if_sample {
    UInt16 index;
    UInt64 bytes_in;
    UInt64 bytes_out;
} if_sample;

// Not thread-safe: call getInterfaceStats from a single serial queue.
@interface NetInfo : NSObject {
    struct net_info info;
    char *buf;
    size_t bufCapacity;
    if_sample *prevSamples;
    int prevCount;
    int prevCapacity;
    if_sample *curSamples;
    int curCapacity;
    uint64_t lastSampleTimeNs;
}

- (net_info*)getInterfaceStats;

@end

#endif /* NetInfo_h */
