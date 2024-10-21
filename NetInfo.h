#ifndef NetInfo_h
#define NetInfo_h

#import <Foundation/Foundation.h>

typedef struct net_info {
    UInt64 total_bytes_in;
    UInt64 total_bytes_out;
    UInt64 delta_bytes_in;
    UInt64 delta_bytes_out;
} net_info;

@interface NetInfo : NSObject {
    struct net_info info;
    BOOL initial;
}

- (net_info*)getInterfaceStats;

@end

#endif /* NetInfo_h */
