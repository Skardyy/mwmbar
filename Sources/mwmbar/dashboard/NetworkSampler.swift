import CoreWLAN
import Darwin
import Foundation

struct NetworkSummary: Sendable {
  var linkKind: LinkKind
  var linkName: String?
  var signalBars: Int?
  var localIP: String?
  var publicIP: String?
  var vpnActive: Bool
}

final class NetworkSampler: @unchecked Sendable {
  private let publicUrl = URL(string: "https://api.ipify.org")!

  func summary() -> NetworkSummary {
    let link = Self.detectLink()
    return NetworkSummary(
      linkKind: link.kind,
      linkName: link.name,
      signalBars: link.bars,
      localIP: Self.primaryLocalIP(),
      publicIP: fetchPublicIP(),
      vpnActive: Self.vpnActive())
  }

  // detect which link type is primary: wifi if CoreWLAN says so, else the
  // first en* interface with an ipv4; vpn-only (no en* ipv4) falls back
  // to the tun interface name.
  private static func detectLink() -> (kind: LinkKind, name: String?, bars: Int?) {
    let wifi = Self.wifi()
    if wifi.ssid != nil {
      return (.wifi, wifi.ssid, wifi.bars)
    }
    for name in ["en0", "en1", "en2", "en3", "en4", "en5", "en6", "en7"] {
      if ipv4(forInterface: name) != nil {
        return (.wired, name, nil)
      }
    }
    for name in ["utun0", "utun1", "utun2", "utun3", "utun4"] {
      if ipv4(forInterface: name) != nil {
        return (.vpn, name, nil)
      }
    }
    return (.unknown, nil, nil)
  }

  // -- wifi --------------------------------------------------------------

  private static func wifi() -> (ssid: String?, bars: Int?) {
    guard let iface = CWWiFiClient.shared().interface() else { return (nil, nil) }
    let ssid = iface.ssid()
    let rssi = iface.rssiValue()
    let bars: Int? = rssi == 0 ? nil : rssiToBars(rssi)
    return (ssid?.isEmpty == false ? ssid : nil, bars)
  }

  // -70 and better is usable; -50 and better is excellent. map to 0..4 bars.
  private static func rssiToBars(_ rssi: Int) -> Int {
    switch rssi {
    case ..<(-80): return 1
    case ..<(-70): return 2
    case ..<(-60): return 3
    default: return 4
    }
  }

  // -- local ip ----------------------------------------------------------

  private static func primaryLocalIP() -> String? {
    for name in ["en0", "en1", "en2"] {
      if let ip = ipv4(forInterface: name) { return ip }
    }
    return nil
  }

  private static func ipv4(forInterface name: String) -> String? {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return nil }
    defer { freeifaddrs(head) }
    var cur: UnsafeMutablePointer<ifaddrs>? = first
    while let ptr = cur {
      let ifa = ptr.pointee
      let ifName = String(cString: ifa.ifa_name)
      if ifName == name, let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        if getnameinfo(
          addr, socklen_t(addr.pointee.sa_len), &buf, socklen_t(buf.count),
          nil, 0, NI_NUMERICHOST) == 0
        {
          return String(cString: buf)
        }
      }
      cur = ifa.ifa_next
    }
    return nil
  }

  // -- vpn ---------------------------------------------------------------

  // utun interfaces with an assigned ipv4 are a strong signal for an active
  // tunnel (tailscale, wireguard, openvpn). plain utun0 without an address
  // exists even without a vpn, so the ipv4 check matters.
  private static func vpnActive() -> Bool {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return false }
    defer { freeifaddrs(head) }
    var cur: UnsafeMutablePointer<ifaddrs>? = first
    while let ptr = cur {
      let ifa = ptr.pointee
      let name = String(cString: ifa.ifa_name)
      if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp"),
        let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET)
      {
        return true
      }
      cur = ifa.ifa_next
    }
    return false
  }

  // -- public ip ---------------------------------------------------------

  private func fetchPublicIP() -> String? {
    let sem = DispatchSemaphore(value: 0)
    var result: String?
    var req = URLRequest(url: publicUrl, timeoutInterval: 3)
    req.httpMethod = "GET"
    URLSession.shared.dataTask(with: req) { data, _, _ in
      if let data, let s = String(data: data, encoding: .utf8) {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result = trimmed }
      }
      sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 4)
    return result
  }

  // -- reverse dns -------------------------------------------------------

  static func reverseDns(_ ip: String) -> String? {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(ip, nil, &hints, &res) == 0, let info = res else { return nil }
    defer { freeaddrinfo(info) }
    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let r = getnameinfo(
      info.pointee.ai_addr, info.pointee.ai_addrlen,
      &buf, socklen_t(buf.count), nil, 0, NI_NAMEREQD)
    guard r == 0 else { return nil }
    let name = String(cString: buf)
    return name == ip ? nil : name
  }
}
