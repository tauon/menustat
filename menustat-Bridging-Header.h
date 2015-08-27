#import "CPUInfo.h"
#import <sys/sysctl.h>
#import <mach/mach_init.h>

struct sockaddr_dl {
    u_char	sdl_len;	/* Total length of sockaddr */
    u_char	sdl_family;	/* AF_LINK */
    u_short	sdl_index;	/* if != 0, system given index for interface */
    u_char	sdl_type;	/* interface type */
    u_char	sdl_nlen;	/* interface name length, no trailing 0 reqd. */
    u_char	sdl_alen;	/* link level address length */
    u_char	sdl_slen;	/* link layer selector length */
    uint8	sdl_data[12];	/* minimum work area, can be larger;
                             contains both if name and ll address */
};