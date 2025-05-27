#import "NetInfo.h"
#include <sys/sysctl.h>
#include <net/if.h>
#include <net/route.h>

@implementation NetInfo

- (instancetype)init {
    self = [super init];
    if (self) {
        memset(&info, 0, sizeof(struct net_info));
        initial = YES;
    }
    return self;
}

- (net_info*)getInterfaceStats {
    int mib[6] = {
        CTL_NET, // networking subsystem
        PF_ROUTE, // type of information
        0, // protocol (IPPROTO_xxx)
        0, // address family
        NET_RT_IFLIST2, // operation
        0
    };
    size_t len;
    if (sysctl(mib, 6, NULL, &len, NULL, 0) < 0) {
        perror("sysctl");
        return NULL;
    }
    char *buf = malloc(len);
    if (buf == NULL) {
        perror("malloc");
        return NULL;
    }
    if (sysctl(mib, 6, buf, &len, NULL, 0) < 0) {
        perror("sysctl");
        free(buf);
        return NULL;
    }

    char *lim = buf + len;
    char *next = buf;
    UInt64 total_bytes_in = 0;
    UInt64 total_bytes_out = 0;

    while (next < lim) {
        struct if_msghdr *ifm = (struct if_msghdr *)next;
        next += ifm->ifm_msglen;
        if (ifm->ifm_type == RTM_IFINFO2) {
            struct if_msghdr2 *if2m = (struct if_msghdr2 *)ifm;
            total_bytes_in += if2m->ifm_data.ifi_ibytes;
            total_bytes_out += if2m->ifm_data.ifi_obytes;
        }
    }
    free(buf);

    if (!initial) {
        // Check for counter reset or overflow - if new total is less than previous total,
        // or if the delta would be unreasonably large, reset the delta to 0
        const UInt64 MAX_REASONABLE_DELTA = 10ULL * 1024ULL * 1024ULL * 1024ULL; // 10GB per second max
        
        if (total_bytes_in >= info.total_bytes_in) {
            UInt64 delta_in = total_bytes_in - info.total_bytes_in;
            info.delta_bytes_in = (delta_in <= MAX_REASONABLE_DELTA) ? delta_in : 0;
        } else {
            // Counter reset detected
            info.delta_bytes_in = 0;
        }
        
        if (total_bytes_out >= info.total_bytes_out) {
            UInt64 delta_out = total_bytes_out - info.total_bytes_out;
            info.delta_bytes_out = (delta_out <= MAX_REASONABLE_DELTA) ? delta_out : 0;
        } else {
            // Counter reset detected
            info.delta_bytes_out = 0;
        }
    } else {
        info.delta_bytes_in = 0;
        info.delta_bytes_out = 0;
        initial = NO;
    }
    info.total_bytes_in = total_bytes_in;
    info.total_bytes_out = total_bytes_out;
    return &info;
}

@end
