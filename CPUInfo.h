//
//  CPUInfo.h
//  menustat
//
//  Created by jeff on 6/10/15.

#ifndef CPUInfo_h
#define CPUInfo_h

#import <Foundation/Foundation.h>

@interface CPUInfo : NSObject

struct cpusample {
    uint64_t totalSystemTime;
    uint64_t totalUserTime;
    uint64_t totalIdleTime;
    
};

struct Load {
    integer_t idle;
    integer_t busy;
};

struct LoadDeltas {
    struct Load* loads;
    integer_t numCores;
};

- (struct LoadDeltas*)getLoad;

@end

#endif /* CPUInfo_h */
