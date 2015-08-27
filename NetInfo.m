//
//  NetInfo.m
//  menustat
//
//  Created by muon on 6/10/15.
//  Copyright © 2015 digitalsophistry. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "NetInfo.h"

#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <net/if.h>
#include <sys/kern_event.h>
#include <sys/kern_control.h>

@implementation NetInfo

typedef	u_int32_t	nstat_provider_id_t;
typedef	u_int32_t	nstat_src_ref_t;

typedef struct nstat_counts
{
    /* Counters */
    u_int64_t       nstat_rxpackets __attribute__((aligned(8)));
    u_int64_t       nstat_rxbytes   __attribute__((aligned(8)));
    u_int64_t       nstat_txpackets __attribute__((aligned(8)));
    u_int64_t       nstat_txbytes   __attribute__((aligned(8)));
    
    u_int32_t       nstat_rxduplicatebytes;
    u_int32_t       nstat_rxoutoforderbytes;
    u_int32_t       nstat_txretransmit;
    
    u_int32_t       nstat_connectattempts;
    u_int32_t       nstat_connectsuccesses;
    
    u_int32_t       nstat_min_rtt;
    u_int32_t       nstat_avg_rtt;
    u_int32_t       nstat_var_rtt;
} nstat_counts;

typedef struct nstat_msg_hdr
{
    u_int64_t	context;
    u_int32_t	type;
    u_int32_t	pad; // unused for now
} nstat_msg_hdr;

typedef struct nstat_msg_src_counts
{
    nstat_msg_hdr           hdr;
    nstat_src_ref_t         srcref;
    nstat_counts            counts;
} nstat_msg_src_counts;

typedef struct nstat_msg_query_src
{
    nstat_msg_hdr		hdr;
    nstat_src_ref_t		srcref;
} nstat_msg_query_src_req;

//typedef struct ctl_info {
//    u_int32_t ctl_id; /* Kernel Controller ID */
//    char ctl_name[96  ]; /* Kernel Controller Name (a C string) */
//} ctl_info;

-(uint)getTransmitBytes {
    char buffer[2048];
    struct sockaddr_ctl       addr;
    struct ctl_info info;
    int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if(fd == -1) {
        fprintf(stderr, "failed to open socket\n");
        return 0;
    }
    bzero(&addr, sizeof(addr));
    addr.sc_len = sizeof(addr);
    addr.sc_family = AF_SYSTEM;
    addr.ss_sysaddr = AF_SYS_CONTROL;
    memset(&info, 0, sizeof(info));
    strncpy(info.ctl_name, "com.apple.network.statistics", sizeof(info.ctl_name));
    if (ioctl(fd, CTLIOCGINFO, &info)) {
        perror("Could not get ID for kernel control.\n");
        return 0;
    }
    addr.sc_id = info.ctl_id;
    addr.sc_unit = 0;
    
    int result = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (result) {
        fprintf(stderr, "connect failed %d\n", result);
        return 0;
    }
    while (true) {
        int rc = read(fd, buffer, sizeof(buffer));
        if (rc > 0) {
            fprintf(stdout, "got %d bytes: %d\n", rc, buffer);
        } else {
            printf("got nothing");
        }
    }

//
//    while (1) {
//        fd_set fds;
//        struct timeval to;
//        to.tv_sec = 1;
//        to.tv_usec = 0;
//        FD_ZERO(&fds);
//        FD_SET(s, &fds);
//        rc = select(s +1, &fds, NULL, NULL, &to);
//                            printf("%d\n", rc);
////        if (rc > 0) {
////                        rc = read(s,c,2048);
////            ok = true;
////        } else {
////            qsreq.hdr.type= 1004;//NSTAT_MSG_TYPE_QUERY_SRC   ; // 1004
////            qsreq.srcref= 0xffffffff; //NSTAT_SRC_REF_ALL;
////            qsreq.hdr.context = 1005; // This way I can tell if errors get returned for dead sources
////            rc = write (s, &qsreq, sizeof(qsreq));
////            ok = false;
////        }
//////        rc = read (s, c, 2048);
////        if (ok)
////        {
////            nstat_msg_hdr *ns = (nstat_msg_hdr *) c;
////            switch (ns->type)
////            {
////                case 10001: case 10002: case 10003: case 10004:
////                    rc = process_nstat_msg(c,rc);
////                    break;
////                default:
////                    printf("%d\n", ns->type);
////                    break;
////                    
////            }
////            ok = false;
////        }
//    }
    return 0;
}

typedef struct nstat_msg_get_src_description
{
    nstat_msg_hdr		hdr;
    nstat_src_ref_t		srcref;
} nstat_msg_get_src_description;

char *descriptors[2000];
nstat_counts descriptorCounts[2000];

void
humanReadable (uint64_t	number, char *output)
{
    char unit = 'B';
    
    float num = (float) number;
    if (num < 1024) {}
    else if ( num < 1024*1024) { unit='K'; num /=1024;}
    else if ( num < 1024*1024*1024) { unit='M'; num /=(1024*1024);}
    else if ( num < 1024UL*1024UL*1024UL*1024UL) { unit='G'; num /=(1024*1024 *1024);}
    else { // let's not get carried away here...
    }
    
    sprintf (output, "%5.2f%c", num, unit);
    
    
}

void
update_provider_statistics (int prov)
{
    // the descriptors array holds a textual printable output. I'm piggybacking on that fact
    // and doing minor string parsing, rather than keep all the src_description structs in
    // memory. Let's not forget this is PoC code
    
    char *desc = descriptors[prov];
    
    if (desc)
    {
        // get last tab..
        char *col = strrchr (desc,'\t');
        // get penultimate tab
        if (col)
        {
            *col ='\0';
            col = strrchr (desc,'\t');
            if (col)
            {
                *(col) = '\0';
                
                char humanReadableRX [15];
                char humanReadableTX [15];
                
                if (true)
                    sprintf(desc + strlen(desc), "\t%7lld\t%7lld", descriptorCounts[prov].nstat_rxpackets, descriptorCounts[prov].nstat_txpackets);
                else
                    if (true)
                    {
                        humanReadable(descriptorCounts[prov].nstat_rxbytes, humanReadableRX);
                        humanReadable(descriptorCounts[prov].nstat_txbytes, humanReadableTX);
                        sprintf(desc + strlen(desc), "\t%s\t%s", humanReadableRX, humanReadableTX);
                        
                    }
                    else
                    {
                        sprintf(desc + strlen(desc), "\t%lld\t%lld", descriptorCounts[prov].nstat_rxbytes, descriptorCounts[prov].nstat_txbytes);
                    }
                
            }
        }
        
    }
}

int
process_nstat_msg (void *msg, int size)
{
    
    nstat_msg_hdr *ns = (nstat_msg_hdr *) msg;
    switch (ns->type)
    {
        case 10004://NSTAT_MSG_TYPE_SRC_COUNTS: //              = 10004
        {
            nstat_msg_src_counts *nmsc = (nstat_msg_src_counts *) (ns );
            memcpy (&(descriptorCounts[nmsc->srcref]), &(nmsc->counts), sizeof (nstat_counts));
            update_provider_statistics (nmsc->srcref);
        }
            
            break;
            
        case 1: 
        {
            if (ns->context < 2000 && !descriptors[ns->context]) break;
            printf ("ERROR for context %lld - should be available\n", ns->context); break; 
        }
        case 0: // printf("Success\n"); break;
            break;
        default:
            printf("Type : %d\n", ns->type);
    }
    fflush(NULL);
    return (ns->type) ;
}

@end