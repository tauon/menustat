//
//  NetInfo.swift
//  menustat
//
//  Created by jeff on 6/11/15.

import Foundation

struct IFStats {
    var incoming:UInt32
    var outgoing:UInt32
    var totalin:UInt32
    var totalout:UInt32
    var peak:UInt32
}

class NetInfo {
    var buffer = Array<UInt8>(count: 2048, repeatedValue: 0)
    
    func getInterfaceStats() -> Dictionary<String, IFStats> {
        var stats = Dictionary<String, IFStats>()
        var mib:[Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST, 0]
        var currentSize:Int = 0
        if sysctl(&mib, u_int(6), nil, &currentSize, nil, 0) != 0 {
            return stats
        }
        if currentSize > buffer.count {
            buffer = Array<UInt8>(count: currentSize, repeatedValue: 0)
        }
        if (sysctl(&mib, 6, &buffer, &currentSize, nil, 0) != 0) {
            return stats
        }
        var currentData:UnsafePointer<UInt8> = UnsafePointer<UInt8>(buffer)
        let endData:UnsafePointer<UInt8> = currentData + currentSize
        while(currentData < endData) {
            let ifmsg_ptr = UnsafePointer<if_msghdr>(currentData)
            let ifmsg = ifmsg_ptr.memory
            if Int32(ifmsg.ifm_type) != RTM_IFINFO {
                currentData = currentData.advancedBy(Int(ifmsg.ifm_msglen))
                continue
            }
            if ifmsg.ifm_flags & IFF_LOOPBACK != 0 {
                currentData = currentData.advancedBy(Int(ifmsg.ifm_msglen))
                continue
            }
            let sdl = UnsafePointer<sockaddr_dl>(ifmsg_ptr + 1).memory
            if sdl.sdl_family != u_char(AF_LINK) {
                currentData = currentData.advancedBy(Int(ifmsg.ifm_msglen))
                continue
            }
            let ifName = NSString(
                bytes: [sdl.sdl_data],
                length: Int(sdl.sdl_nlen),
                encoding: NSASCIIStringEncoding)
            if (ifName == nil) {
                currentData = currentData.advancedBy(Int(ifmsg.ifm_msglen))
                continue
            }
            let ifstats = IFStats(
                incoming: ifmsg.ifm_data.ifi_ibytes,
                outgoing: ifmsg.ifm_data.ifi_obytes,
                totalin: ifmsg.ifm_data.ifi_ibytes,
                totalout: ifmsg.ifm_data.ifi_obytes,
                peak: max(ifmsg.ifm_data.ifi_ibytes, ifmsg.ifm_data.ifi_obytes))
            stats[String(ifName!)] = ifstats
            currentData = currentData.advancedBy(Int(ifmsg.ifm_msglen))
        }
        return(stats)
    }
}