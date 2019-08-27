//
//  NetInfo.m
//  menustat
//
//  Created by jeff on 6/10/15.

#import <Foundation/Foundation.h>
#import "NetInfo.h"

#include <sys/sysctl.h>
#include <net/if.h>

// Route message from bsd/net/route.h
#define RTM_IFINFO2 0x12

@implementation NetInfo

struct net_info info = { 0, 0, 0, 0 };
bool initial = true;

-(net_info*)getInterfaceStats {
    // from netstat implementation
    int mib[] = {
        CTL_NET, // networking subsystem
        PF_ROUTE, // type of information
        0, // protocol (IPPROTO_xxx)
        0, // address family
        NET_RT_IFLIST2, // operation
        0
    };
    size_t len;
    char *buf = NULL;
    char *lim = NULL;
    if (sysctl(mib, 6, NULL, &len, NULL, 0) < 0) {
        fprintf(stderr, "sysctl: %s\n", strerror(errno));
        exit(1);
    }
    if ((buf = malloc(len)) == NULL) {
        printf("malloc failed\n");
        exit(1);
    }
    if (sysctl(mib, 6, buf, &len, NULL, 0) < 0) {
        fprintf(stderr, "sysctl: %s\n", strerror(errno));
        exit(1);
    }
    lim = buf + len;
    char *next = NULL;
    u_int64_t total_bytes_in = 0;
    u_int64_t total_bytes_out = 0;
    for (next = buf; next < lim; ) {
        struct if_msghdr *ifm = (struct if_msghdr *)next;
        next += ifm->ifm_msglen;
        if (ifm->ifm_type == RTM_IFINFO2) {
            struct if_msghdr2 *if2m = (struct if_msghdr2 *)ifm;
            total_bytes_in += if2m->ifm_data.ifi_ibytes;
            total_bytes_out += if2m->ifm_data.ifi_obytes;
        }
    }
    free(buf);
    if(!initial) {
        info.delta_bytes_in = total_bytes_in - info.total_bytes_in;
        info.delta_bytes_out = total_bytes_out - info.total_bytes_out;
    }
    info.total_bytes_in = total_bytes_in;
    info.total_bytes_out = total_bytes_out;
    initial = false;
    return &info;
}

@end
