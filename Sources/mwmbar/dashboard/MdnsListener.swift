import Darwin
import Foundation
import dnssd

/// one mDNS announcement observed on the local link.
struct MdnsRecord {
  let ip: String
  let hostname: String?
  let serviceType: String
}

// name = "_airplay._tcp", regtype = "_tcp.local." -> "_airplay._tcp."
// regtype trails as "_tcp.local." or "_udp.local." so take the first
// segment and glue to the service name.
private func stitchMetaType(name: String, regtype: String) -> String {
  let proto = regtype.split(separator: ".").first.map { "." + $0 } ?? ""
  return name + String(proto) + "."
}

/// continuous passive mDNS listener. kicks off a meta browse to learn
/// what service types are being announced on the link, then opens a
/// long-lived browse per type and streams every (ip, hostname) pair as
/// devices advertise themselves. uses the dns_sd C API with
/// DNSServiceSetDispatchQueue since the Foundation NetServiceBrowser
/// wrapper does not deliver callbacks on background threads.
final class MdnsListener: @unchecked Sendable {
  private let queue = DispatchQueue(label: "mwmbar.mdns", qos: .utility)
  private let lock = NSLock()
  private var refs: [DNSServiceRef] = []
  private var running = false
  private var onRecord: (@Sendable (MdnsRecord) -> Void)?

  func start(onRecord: @escaping @Sendable (MdnsRecord) -> Void) {
    stop()
    lock.withLock {
      self.onRecord = onRecord
      self.running = true
    }
    queue.async { [weak self] in self?.launchMeta() }
  }

  func stop() {
    lock.withLock {
      self.running = false
      for ref in refs { DNSServiceRefDeallocate(ref) }
      refs.removeAll()
      self.onRecord = nil
    }
  }

  private func launchMeta() {
    let ctxPtr = Unmanaged.passUnretained(self).toOpaque()
    var ref: DNSServiceRef?
    let err = DNSServiceBrowse(
      &ref, 0, 0, "_services._dns-sd._udp", "local.", metaCallback, ctxPtr)
    guard err == kDNSServiceErr_NoError, let ref else { return }
    DNSServiceSetDispatchQueue(ref, queue)
    lock.withLock { if running { refs.append(ref) } else { DNSServiceRefDeallocate(ref) } }
  }

  fileprivate func onMetaType(_ full: String) {
    queue.async { [weak self] in self?.browseType(full) }
  }

  private var browsingTypes: Set<String> = []

  private func browseType(_ type: String) {
    let shouldBrowse: Bool = lock.withLock {
      guard running, !browsingTypes.contains(type) else { return false }
      browsingTypes.insert(type)
      return true
    }
    guard shouldBrowse else { return }
    let ctxPtr = Unmanaged.passRetained(TypeContext(parent: self, type: type)).toOpaque()
    var ref: DNSServiceRef?
    let err = DNSServiceBrowse(&ref, 0, 0, type, "local.", typeCallback, ctxPtr)
    guard err == kDNSServiceErr_NoError, let ref else {
      _ = Unmanaged<TypeContext>.fromOpaque(ctxPtr).takeRetainedValue()
      return
    }
    DNSServiceSetDispatchQueue(ref, queue)
    lock.withLock { if running { refs.append(ref) } else { DNSServiceRefDeallocate(ref) } }
  }

  fileprivate func onInstance(name: String, regtype: String, domain: String, type: String) {
    queue.async { [weak self] in
      self?.resolve(name: name, regtype: regtype, domain: domain, type: type)
    }
  }

  private func resolve(name: String, regtype: String, domain: String, type: String) {
    let ctxPtr = Unmanaged.passRetained(ResolveContext(parent: self, type: type)).toOpaque()
    var ref: DNSServiceRef?
    let err = DNSServiceResolve(
      &ref, 0, 0, name, regtype, domain, resolveCallback, ctxPtr)
    guard err == kDNSServiceErr_NoError, let ref else {
      _ = Unmanaged<ResolveContext>.fromOpaque(ctxPtr).takeRetainedValue()
      return
    }
    DNSServiceSetDispatchQueue(ref, queue)
    lock.withLock { if running { refs.append(ref) } else { DNSServiceRefDeallocate(ref) } }
  }

  fileprivate func onHost(_ host: String, type: String) {
    queue.async { [weak self] in self?.address(host: host, type: type) }
  }

  private func address(host: String, type: String) {
    let ctxPtr = Unmanaged.passRetained(AddrContext(parent: self, host: host, type: type))
      .toOpaque()
    var ref: DNSServiceRef?
    let err = DNSServiceGetAddrInfo(
      &ref, 0, 0, DNSServiceProtocol(kDNSServiceProtocol_IPv4), host,
      addrCallback, ctxPtr)
    guard err == kDNSServiceErr_NoError, let ref else {
      _ = Unmanaged<AddrContext>.fromOpaque(ctxPtr).takeRetainedValue()
      return
    }
    DNSServiceSetDispatchQueue(ref, queue)
    lock.withLock { if running { refs.append(ref) } else { DNSServiceRefDeallocate(ref) } }
  }

  fileprivate func deliver(ip: String, hostname: String?, type: String) {
    let cb = lock.withLock { onRecord }
    cb?(MdnsRecord(ip: ip, hostname: hostname, serviceType: humanServiceName(type)))
  }

  private func humanServiceName(_ type: String) -> String {
    var s = type
    if s.hasSuffix(".") { s.removeLast() }
    if s.hasSuffix("._tcp") { s.removeLast(5) }
    if s.hasSuffix("._udp") { s.removeLast(5) }
    if s.hasPrefix("_") { s.removeFirst() }
    return s
  }
}

// each context is retained on the C side via Unmanaged.passRetained and
// released on the first callback. the parent listener keeps the ref in
// its `refs` array so it stays alive for the duration of the browse.
private final class TypeContext {
  let parent: MdnsListener
  let type: String
  init(parent: MdnsListener, type: String) {
    self.parent = parent
    self.type = type
  }
}

private final class ResolveContext {
  let parent: MdnsListener
  let type: String
  init(parent: MdnsListener, type: String) {
    self.parent = parent
    self.type = type
  }
}

private final class AddrContext {
  let parent: MdnsListener
  let host: String
  let type: String
  init(parent: MdnsListener, host: String, type: String) {
    self.parent = parent
    self.host = host
    self.type = type
  }
}

// C callbacks are file scope so they can be @convention(c).

private func metaCallback(
  _ ref: DNSServiceRef?, _ flags: DNSServiceFlags, _ iface: UInt32,
  _ err: DNSServiceErrorType, _ name: UnsafePointer<CChar>?,
  _ regtype: UnsafePointer<CChar>?, _ domain: UnsafePointer<CChar>?,
  _ context: UnsafeMutableRawPointer?
) {
  guard err == kDNSServiceErr_NoError, let name, let regtype, let context else { return }
  let listener = Unmanaged<MdnsListener>.fromOpaque(context).takeUnretainedValue()
  let full = stitchMetaType(name: String(cString: name), regtype: String(cString: regtype))
  listener.onMetaType(full)
}

private func typeCallback(
  _ ref: DNSServiceRef?, _ flags: DNSServiceFlags, _ iface: UInt32,
  _ err: DNSServiceErrorType, _ name: UnsafePointer<CChar>?,
  _ regtype: UnsafePointer<CChar>?, _ domain: UnsafePointer<CChar>?,
  _ context: UnsafeMutableRawPointer?
) {
  guard let context else { return }
  let ctx = Unmanaged<TypeContext>.fromOpaque(context).takeUnretainedValue()
  guard err == kDNSServiceErr_NoError, let name, let regtype, let domain else { return }
  ctx.parent.onInstance(
    name: String(cString: name), regtype: String(cString: regtype),
    domain: String(cString: domain), type: ctx.type)
}

private func resolveCallback(
  _ ref: DNSServiceRef?, _ flags: DNSServiceFlags, _ iface: UInt32,
  _ err: DNSServiceErrorType, _ fullname: UnsafePointer<CChar>?,
  _ hosttarget: UnsafePointer<CChar>?, _ port: UInt16,
  _ txtLen: UInt16, _ txtRecord: UnsafePointer<UInt8>?,
  _ context: UnsafeMutableRawPointer?
) {
  guard let context else { return }
  let ctx = Unmanaged<ResolveContext>.fromOpaque(context).takeUnretainedValue()
  guard err == kDNSServiceErr_NoError, let hosttarget else { return }
  ctx.parent.onHost(String(cString: hosttarget), type: ctx.type)
}

private func addrCallback(
  _ ref: DNSServiceRef?, _ flags: DNSServiceFlags, _ iface: UInt32,
  _ err: DNSServiceErrorType, _ hostname: UnsafePointer<CChar>?,
  _ addr: UnsafePointer<sockaddr>?, _ ttl: UInt32,
  _ context: UnsafeMutableRawPointer?
) {
  guard let context else { return }
  let ctx = Unmanaged<AddrContext>.fromOpaque(context).takeUnretainedValue()
  guard err == kDNSServiceErr_NoError, let addr else { return }
  if addr.pointee.sa_family != UInt8(AF_INET) { return }
  var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
  guard
    getnameinfo(
      addr, socklen_t(addr.pointee.sa_len), &buf, socklen_t(buf.count),
      nil, 0, NI_NUMERICHOST) == 0
  else { return }
  let ip = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
  ctx.parent.deliver(ip: ip, hostname: ctx.host, type: ctx.type)
}
