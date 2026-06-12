#import "NetInfo.h"
#include <errno.h>
#include <time.h>
#include <sys/sysctl.h>
#include <net/if.h>
#include <net/if_types.h>
#include <net/route.h>

@implementation NetInfo

- (instancetype)init {
    self = [super init];
    if (self) {
        memset(&info, 0, sizeof(struct net_info));
    }
    return self;
}

- (void)dealloc {
    free(buf);
    free(prevSamples);
    free(curSamples);
}

// Fetches NET_RT_IFLIST2 into the reused buffer. Retries because the required
// size can grow between the size query and the fetch (sysctl returns ENOMEM).
- (BOOL)fetchInterfaceList:(size_t *)outLen {
    int mib[6] = {
        CTL_NET, // networking subsystem
        PF_ROUTE, // type of information
        0, // protocol (IPPROTO_xxx)
        0, // address family
        NET_RT_IFLIST2, // operation
        0
    };
    for (int attempt = 0; attempt < 4; attempt++) {
        size_t len;
        if (sysctl(mib, 6, NULL, &len, NULL, 0) < 0) {
            return NO;
        }
        if (len > bufCapacity) {
            size_t newCapacity = len + len / 4;
            char *newBuf = realloc(buf, newCapacity);
            if (newBuf == NULL) {
                return NO;
            }
            buf = newBuf;
            bufCapacity = newCapacity;
        }
        len = bufCapacity;
        if (sysctl(mib, 6, buf, &len, NULL, 0) == 0) {
            *outLen = len;
            return YES;
        }
        if (errno != ENOMEM) {
            return NO;
        }
    }
    return NO;
}

- (net_info*)getInterfaceStats {
    size_t len = 0;
    if (![self fetchInterfaceList:&len]) {
        return NULL;
    }
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);

    char *lim = buf + len;
    char *next = buf;
    UInt64 total_bytes_in = 0;
    UInt64 total_bytes_out = 0;
    int count = 0;

    while (next < lim) {
        struct if_msghdr *ifm = (struct if_msghdr *)next;
        if (ifm->ifm_msglen == 0) {
            break;
        }
        next += ifm->ifm_msglen;
        if (ifm->ifm_type != RTM_IFINFO2) {
            continue;
        }
        struct if_msghdr2 *if2m = (struct if_msghdr2 *)ifm;
        if (if2m->ifm_data.ifi_type == IFT_LOOP) {
            continue; // loopback is local IPC, not network traffic
        }
        if (count == curCapacity) {
            int newCapacity = curCapacity ? curCapacity * 2 : 16;
            if_sample *grown = realloc(curSamples, newCapacity * sizeof(if_sample));
            if (grown == NULL) {
                return NULL;
            }
            curSamples = grown;
            curCapacity = newCapacity;
        }
        curSamples[count].index = if2m->ifm_index;
        curSamples[count].bytes_in = if2m->ifm_data.ifi_ibytes;
        curSamples[count].bytes_out = if2m->ifm_data.ifi_obytes;
        total_bytes_in += if2m->ifm_data.ifi_ibytes;
        total_bytes_out += if2m->ifm_data.ifi_obytes;
        count++;
    }

    // Delta per interface, matched by index. An interface that vanished
    // contributes nothing; one that (re)appeared has no baseline yet, so it
    // starts contributing next sample. This keeps a single interface bouncing
    // from injecting its since-boot byte count into one sample's delta.
    UInt64 delta_in = 0;
    UInt64 delta_out = 0;
    for (int i = 0; i < count; i++) {
        for (int j = 0; j < prevCount; j++) {
            if (prevSamples[j].index != curSamples[i].index) {
                continue;
            }
            if (curSamples[i].bytes_in >= prevSamples[j].bytes_in) {
                delta_in += curSamples[i].bytes_in - prevSamples[j].bytes_in;
            }
            if (curSamples[i].bytes_out >= prevSamples[j].bytes_out) {
                delta_out += curSamples[i].bytes_out - prevSamples[j].bytes_out;
            }
            break;
        }
    }

    if (lastSampleTimeNs != 0 && now > lastSampleTimeNs) {
        double elapsedSeconds = (double)(now - lastSampleTimeNs) / 1e9;
        info.delta_bytes_in = (UInt64)((double)delta_in / elapsedSeconds);
        info.delta_bytes_out = (UInt64)((double)delta_out / elapsedSeconds);
    } else {
        info.delta_bytes_in = 0;
        info.delta_bytes_out = 0;
    }
    lastSampleTimeNs = now;
    info.total_bytes_in = total_bytes_in;
    info.total_bytes_out = total_bytes_out;

    if_sample *tmpSamples = prevSamples;
    int tmpCapacity = prevCapacity;
    prevSamples = curSamples;
    prevCapacity = curCapacity;
    prevCount = count;
    curSamples = tmpSamples;
    curCapacity = tmpCapacity;

    return &info;
}

@end
