import CoreWLAN
import Darwin
import Foundation
import Network

struct NetworkSummary: Sendable {
  var linkKind: LinkKind
  var linkName: String?
  var signalBars: Int?
  var localIP: String?
  var vpnActive: Bool
}

struct InterfaceInfo: Identifiable, Sendable, Equatable {
  let name: String
  let isUp: Bool
  let isRunning: Bool
  let isLoopback: Bool
  let ipv4: String?
  let mac: String?
  var id: String { name }
}

final class NetworkSampler: @unchecked Sendable {
  private let publicUrl = URL(string: "https://api.ipify.org")!
  private let pathMonitor = NWPathMonitor()
  private let pathQueue = DispatchQueue(label: "mwmbar.network.path")
  private let pathLock = NSLock()
  private var cachedPath: NWPath?

  init() {
    pathMonitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      self.pathLock.withLock { self.cachedPath = path }
    }
    pathMonitor.start(queue: pathQueue)
  }

  deinit {
    pathMonitor.cancel()
  }

  // every interface getifaddrs reports, up or down, with its ipv4 and mac
  // when available. one pass merges the AF_INET and AF_LINK records that
  // getifaddrs reports as separate entries per interface name.
  func allInterfaces() -> [InterfaceInfo] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }

    struct Builder {
      var isUp = false
      var isRunning = false
      var isLoopback = false
      var ipv4: String?
      var mac: String?
    }
    var order: [String] = []
    var byName: [String: Builder] = [:]

    var cur: UnsafeMutablePointer<ifaddrs>? = first
    while let ptr = cur {
      defer { cur = ptr.pointee.ifa_next }
      let ifa = ptr.pointee
      let name = String(cString: ifa.ifa_name)
      if byName[name] == nil {
        byName[name] = Builder()
        order.append(name)
      }
      byName[name]!.isUp = (ifa.ifa_flags & UInt32(IFF_UP)) != 0
      byName[name]!.isRunning = (ifa.ifa_flags & UInt32(IFF_RUNNING)) != 0
      byName[name]!.isLoopback = (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) != 0

      guard let addr = ifa.ifa_addr else { continue }
      if addr.pointee.sa_family == UInt8(AF_INET) {
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        if getnameinfo(
          addr, socklen_t(addr.pointee.sa_len), &buf, socklen_t(buf.count),
          nil, 0, NI_NUMERICHOST) == 0
        {
          byName[name]!.ipv4 = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }
      } else if addr.pointee.sa_family == UInt8(AF_LINK) {
        // sockaddr_dl header is 8 bytes (len, family, index, type, nlen,
        // alen, slen) before the variable length name + address data; read
        // raw bytes off the original buffer rather than the Swift bridged
        // struct, whose sdl_data tuple is fixed at 12 bytes and can truncate
        // a long interface name before the mac bytes it precedes.
        let raw = UnsafeRawPointer(addr)
        let nlen = Int(raw.load(fromByteOffset: 5, as: UInt8.self))
        let alen = Int(raw.load(fromByteOffset: 6, as: UInt8.self))
        if alen == 6 {
          let macBytes = raw.advanced(by: 8 + nlen).assumingMemoryBound(to: UInt8.self)
          byName[name]!.mac = (0..<6)
            .map { String(format: "%02x", macBytes[$0]) }
            .joined(separator: ":")
        }
      }
    }

    return order.compactMap { name in
      guard let b = byName[name] else { return nil }
      return InterfaceInfo(
        name: name, isUp: b.isUp, isRunning: b.isRunning, isLoopback: b.isLoopback,
        ipv4: b.ipv4, mac: b.mac)
    }
  }

  func summary() -> NetworkSummary {
    let interfaces = Self.ipv4Interfaces()
    let path = pathLock.withLock { cachedPath }
    let link = Self.detectLink(interfaces: interfaces, path: path)
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

  // the OS's own picked primary interface via NWPathMonitor. order of
  // availableInterfaces matches what macOS uses to route new outbound
  // connections, so this mirrors the status-bar connectivity icon.
  private static func detectLink(
    interfaces: [Iface], path: NWPath?
  )
    -> (kind: LinkKind, name: String?, bars: Int?)
  {
    guard let primary = path?.availableInterfaces.first else {
      return (.unknown, nil, nil)
    }
    switch primary.type {
    case .wifi:
      return (.wifi, primary.name, Self.wifi().bars)
    case .wiredEthernet:
      return (.wired, primary.name, nil)
    case .cellular:
      return (.vpn, primary.name, nil)
    case .loopback, .other:
      if primary.name.hasPrefix("utun") || primary.name.hasPrefix("ipsec")
        || primary.name.hasPrefix("ppp")
      {
        return (.vpn, primary.name, nil)
      }
      return (.unknown, primary.name, nil)
    @unknown default:
      return (.unknown, primary.name, nil)
    }
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
