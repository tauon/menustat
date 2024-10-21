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
        info.delta_bytes_in = total_bytes_in - info.total_bytes_in;
        info.delta_bytes_out = total_bytes_out - info.total_bytes_out;
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
