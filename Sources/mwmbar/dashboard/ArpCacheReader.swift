import Darwin
import Foundation

/// one (ip, mac) pair read straight from the kernel's own arp cache - the
/// exact same sysctl `arp -a` itself uses internally. zero privilege, zero
/// network traffic of any kind generated; it only ever shows whatever the
/// os already resolved on its own.
struct ArpEntry: Sendable {
  let ip: String
  let mac: String
  let interfaceName: String?
}

enum ArpCacheReader {
  static func read() -> [ArpEntry] {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
    var length = 0
    let sizeResult = sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0)
    guard sizeResult == 0 else {
      Log.network.warning("arp cache: sysctl size query failed, errno \(errno)")
      return []
    }
    // length == 0 just means the kernel's arp table is currently empty,
    // not a failure - nothing to log, this is the expected steady state
    // right after boot or when nothing has been resolved yet.
    guard length > 0 else { return [] }
    var buffer = [UInt8](repeating: 0, count: length)
    guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else {
      Log.network.warning("arp cache: sysctl fetch failed, errno \(errno)")
      return []
    }
    return parse(buffer: buffer, length: length)
  }

  // each record is an rt_msghdr followed by a sockaddr_inarp (the ipv4
  // peer) then a sockaddr_dl (its resolved mac). sockaddr_inarp is not
  // exposed in the public sdk headers, so its fields are read by raw byte
  // offset instead: sin_len(1) sin_family(1) sin_port(2) sin_addr(4) at
  // byte offset 4 within the sockaddr_inarp block.
  private static func parse(buffer: [UInt8], length: Int) -> [ArpEntry] {
    let headerSize = MemoryLayout<rt_msghdr>.size
    var out: [ArpEntry] = []
    var offset = 0
    buffer.withUnsafeBytes { raw in
      while offset + headerSize <= length {
        let messageLength = Int(raw[offset]) | (Int(raw[offset + 1]) << 8)
        guard messageLength > 0, offset + messageLength <= length else { break }
        defer { offset += messageLength }

        let sin = offset + headerSize
        guard sin + 8 <= length, raw[sin + 1] == UInt8(AF_INET) else { continue }
        let ip = (0..<4).map { String(raw[sin + 4 + $0]) }.joined(separator: ".")

        // sockaddr addresses in routing messages are padded to 4 byte
        // boundaries; sin_len (byte 0) is the real, unpadded length.
        let sinLen = Int(raw[sin])
        let dl = sin + ((sinLen + 3) & ~3)
        guard dl + 8 <= length, raw[dl + 1] == UInt8(AF_LINK) else { continue }
        let nameLen = Int(raw[dl + 5])
        let addrLen = Int(raw[dl + 6])
        let macStart = dl + 8 + nameLen
        guard addrLen == 6, macStart + 6 <= length else { continue }
        let mac = (0..<6).map { String(format: "%02x", raw[macStart + $0]) }.joined(
          separator: ":")
        guard mac != "00:00:00:00:00:00", mac != "ff:ff:ff:ff:ff:ff" else { continue }
        // rtm_index (interface index) sits at byte offset 4 of rt_msghdr.
        let index = UInt32(raw[offset + 4]) | (UInt32(raw[offset + 5]) << 8)
        out.append(ArpEntry(ip: ip, mac: mac, interfaceName: interfaceName(for: index)))
      }
    }
    return out
  }

  private static func interfaceName(for index: UInt32) -> String? {
    guard index != 0 else { return nil }
    var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
    guard if_indextoname(index, &buf) != nil else { return nil }
    return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
  }
}
