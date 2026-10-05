#import <Foundation/Foundation.h>
#include <sys/sysctl.h>
#include <net/if.h>
#include <net/if_types.h>
#include <net/route.h>
#include <time.h>
#include <errno.h>
#include <assert.h>

static struct if_msghdr2 messages[32];
static size_t messageCount = 2;
static int sizeQueries, dataQueries;
static uint64_t now = 1000000000;
static size_t truncatedBytes;
static BOOL includeAddress;

static int fixtureSysctl(int *mib, u_int count, void *output, size_t *size,
                         void *input, size_t inputSize) {
    assert(count == 6 && mib[4] == NET_RT_IFLIST2 && !input && !inputSize);
    uint8_t data[sizeof(messages) + sizeof(struct ifa_msghdr)];
    size_t required = messageCount * sizeof(messages[0]);
    memcpy(data, messages, required);
    if (includeAddress) {
        struct ifa_msghdr address = {0};
        address.ifam_msglen = sizeof(address);
        address.ifam_type = RTM_NEWADDR;
        memcpy(data + required, &address, sizeof(address));
        required += sizeof(address);
    }
    required -= truncatedBytes;
    if (!output) {
        sizeQueries++;
        *size = required;
        return 0;
    }
    dataQueries++;
    if (*size < required) { errno = ENOMEM; return -1; }
    memcpy(output, data, required);
    *size = required;
    return 0;
}

static uint64_t fixtureClock(clockid_t clock) { (void)clock; return now; }

#define sysctl fixtureSysctl
#define clock_gettime_nsec_np fixtureClock
#import "../NetInfo.m"
#undef sysctl
#undef clock_gettime_nsec_np

static void interface(size_t row, uint16_t index, uint8_t type, uint64_t rx) {
    messages[row] = (struct if_msghdr2){0};
    messages[row].ifm_msglen = sizeof(messages[0]);
    messages[row].ifm_type = RTM_IFINFO2;
    messages[row].ifm_index = index;
    messages[row].ifm_data.ifi_type = type;
    messages[row].ifm_data.ifi_ibytes = rx;
}

int main(void) {
    @autoreleasepool {
        interface(0, 1, IFT_ETHER, 100);
        interface(1, 2, IFT_LOOP, 100000);
        NetInfo *stats = [NetInfo new];
        assert([stats getInterfaceStats]->delta_bytes_in == 0);
        assert(sizeQueries == 1 && dataQueries == 1);

        now += 2000000000;
        messages[0].ifm_data.ifi_ibytes += 400;
        messages[1].ifm_data.ifi_ibytes += 100000;
        net_info *sample = [stats getInterfaceStats];
        assert(sample->delta_bytes_in == 200 && sample->total_bytes_in == 500);
        assert(sizeQueries == 1 && dataQueries == 2);

        // Grow the route buffer, then reorder/remove/reset interfaces.
        messageCount = 32;
        for (size_t i = 2; i < messageCount; i++) interface(i, (uint16_t)i + 1, IFT_ETHER, 900000);
        now += 1000000000;
        assert([stats getInterfaceStats]->delta_bytes_in == 0);
        assert(sizeQueries == 2 && dataQueries == 4);
        messageCount = 2;
        interface(0, 3, IFT_ETHER, 900600);
        interface(1, 1, IFT_ETHER, 1);
        now += 2000000000;
        assert([stats getInterfaceStats]->delta_bytes_in == 300);

        includeAddress = YES;
        assert([stats getInterfaceStats] != NULL); // Valid shorter route headers.
        includeAddress = NO;

        // One transfer appears on both the physical link and its VPN tunnel.
        // Simultaneous traffic on another link must still contribute.
        messageCount = 8;
        interface(0, 1, IFT_ETHER, 1000);
        interface(1, 3, IFT_ETHER, 2000); // macOS Wi-Fi also reports IFT_ETHER.
        interface(2, 4, IFT_OTHER, 1000); // utun
        interface(3, 5, IFT_BRIDGE, 1000);
        interface(4, 6, IFT_L2VLAN, 1000);
        interface(5, 7, IFT_IEEE8023ADLAG, 1000);
        interface(6, 8, IFT_CELLULAR, 1000);
        interface(7, 9, IFT_IEEE1394, 1000);
        now += 1000000000;
        assert([stats getInterfaceStats] != NULL);
        for (int i = 0; i < 8; i++) {
            messages[i].ifm_data.ifi_ibytes += 1000;
            messages[i].ifm_data.ifi_obytes += 500;
        }
        now += 1000000000;
        sample = [stats getInterfaceStats];
        assert(sample->delta_bytes_in == 4000 && sample->delta_bytes_out == 2000);
        assert(sample->total_bytes_in == 9000 && sample->total_bytes_out == 2000);

        truncatedBytes = sizeof(messages[0]) - 1;
        assert([stats getInterfaceStats] == NULL);
        truncatedBytes = 0;
        messages[0].ifm_msglen = 0;
        assert([stats getInterfaceStats] == NULL);
        puts("PASS: link rates, VPN/bridge/VLAN deduplication, multiple links, churn, route parsing");
    }
}
