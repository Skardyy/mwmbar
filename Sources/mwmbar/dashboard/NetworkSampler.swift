import CoreWLAN
import Darwin
import Foundation

struct NetworkSummary: Sendable {
  var linkKind: LinkKind
  var linkName: String?
  var signalBars: Int?
  var localIP: String?
  var vpnActive: Bool
}

final class NetworkSampler: @unchecked Sendable {
  private let publicUrl = URL(string: "https://api.ipify.org")!

  func summary() -> NetworkSummary {
    let interfaces = Self.ipv4Interfaces()
    let link = Self.detectLink(interfaces: interfaces)
    return NetworkSummary(
      linkKind: link.kind,
      linkName: link.name,
      signalBars: link.bars,
      localIP: Self.primaryLocalIP(interfaces: interfaces),
      vpnActive: Self.vpnActive(interfaces: interfaces))
  }

  // async-first; callers await instead of blocking a background queue on a
  // semaphore. returns nil on timeout / parse failure (silent trace;
  // offline is the common case and does not warrant noise).
  func publicIP() async -> String? {
    var req = URLRequest(url: publicUrl, timeoutInterval: 3)
    req.httpMethod = "GET"
    do {
      let (data, _) = try await URLSession.shared.data(for: req)
      guard let s = String(data: data, encoding: .utf8) else { return nil }
      let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    } catch {
      return nil
    }
  }

  // single getifaddrs walk; downstream classifiers filter by prefix.
  private struct Iface {
    let name: String
    let ip: String
  }

  private static func ipv4Interfaces() -> [Iface] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }
    var out: [Iface] = []
    var cur: UnsafeMutablePointer<ifaddrs>? = first
    while let ptr = cur {
      defer { cur = ptr.pointee.ifa_next }
      let ifa = ptr.pointee
      guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
      let name = String(cString: ifa.ifa_name)
      var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      guard
        getnameinfo(
          addr, socklen_t(addr.pointee.sa_len), &buf, socklen_t(buf.count),
          nil, 0, NI_NUMERICHOST) == 0
      else { continue }
      let ip = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
      out.append(Iface(name: name, ip: ip))
    }
    return out
  }

  private static func detectLink(interfaces: [Iface]) -> (kind: LinkKind, name: String?, bars: Int?)
  {
    let wifi = Self.wifi()
    if wifi.ssid != nil {
      return (.wifi, wifi.ssid, wifi.bars)
    }
    if let wired = interfaces.first(where: { $0.name.hasPrefix("en") }) {
      return (.wired, wired.name, nil)
    }
    if let vpn = interfaces.first(where: {
      $0.name.hasPrefix("utun") || $0.name.hasPrefix("ipsec") || $0.name.hasPrefix("ppp")
    }) {
      return (.vpn, vpn.name, nil)
    }
    return (.unknown, nil, nil)
  }

  private static func wifi() -> (ssid: String?, bars: Int?) {
    guard let iface = CWWiFiClient.shared().interface() else { return (nil, nil) }
    let ssid = iface.ssid()
    let rssi = iface.rssiValue()
    let bars: Int? = rssi == 0 ? nil : rssiToBars(rssi)
    return (ssid?.isEmpty == false ? ssid : nil, bars)
  }

  // -70 dBm is usable, -50 dBm is excellent.
  private static func rssiToBars(_ rssi: Int) -> Int {
    switch rssi {
    case ..<(-80): return 1
    case ..<(-70): return 2
    case ..<(-60): return 3
    default: return 4
    }
  }

  private static func primaryLocalIP(interfaces: [Iface]) -> String? {
    interfaces.first { $0.name.hasPrefix("en") }?.ip
  }

  // utun / ipsec / ppp interfaces with an assigned ipv4 are a strong signal
  // for an active tunnel (tailscale, wireguard, openvpn). plain utun0
  // without an address exists even without a vpn, so the ipv4 check matters.
  private static func vpnActive(interfaces: [Iface]) -> Bool {
    interfaces.contains { iface in
      iface.name.hasPrefix("utun") || iface.name.hasPrefix("ipsec")
        || iface.name.hasPrefix("ppp")
    }
  }
}
