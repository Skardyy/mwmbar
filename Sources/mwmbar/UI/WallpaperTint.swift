import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI

/// per screen wallpaper derived accent. nil channels fall back to BarConfig
/// defaults so a denied Screen Recording prompt leaves the pill looking the
/// same as before.
@Observable
@MainActor
final class WallpaperTint {
  var activeFill: Color?
  var activeStroke: Color?
  var hoverActiveFill: Color?

  @ObservationIgnored private let display: CGDirectDisplayID
  /// region to sample in normalised display coords (0..1), y measured from
  /// the top. passed in by the owning BarWindow so the pill tints to the
  /// pixels actually sitting next to it, not an unrelated corner.
  @ObservationIgnored private let cropFraction: CGRect

  init(display: CGDirectDisplayID, cropFraction: CGRect) {
    self.display = display
    self.cropFraction = cropFraction
  }

  func start() {
    sample()
  }

  func stop() {}

  private func sample() {
    let display = self.display
    let cropFraction = self.cropFraction
    Task.detached(priority: .utility) {
      let base = await WallpaperSampler.sample(display: display, cropFraction: cropFraction)
      await MainActor.run { [weak self] in
        guard let self else { return }
        guard let base else { return }
        let hsl = rgbToHsl(base)
        // non linear boost: amplifies low to mid chroma so the pill reads
        // noticeably against the wallpaper, while a nearly grey base still
        // stays neutral (sqrt(0) == 0).
        let boosted = min(1.0, sqrt(hsl.s))
        self.activeFill = Color(
          nsColor: hslToNsColor(h: hsl.h, s: boosted, l: 0.42)
        ).opacity(0.30)
        self.activeStroke = Color(
          nsColor: hslToNsColor(h: hsl.h, s: boosted, l: 0.78)
        ).opacity(0.80)
        self.hoverActiveFill = Color(
          nsColor: hslToNsColor(h: hsl.h, s: boosted, l: 0.50)
        ).opacity(0.45)
      }
    }
  }

  deinit {
    MainActor.assumeIsolated { self.stop() }
  }
}

/// SCK based desktop pixel grab. filter excludes every running app so only
/// the wallpaper remains, which covers static, dynamic .heic, and video /
/// aerial wallpapers uniformly.
enum WallpaperSampler {
  static func sample(display: CGDirectDisplayID, cropFraction: CGRect) async -> NSColor? {
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
      guard let scDisplay = content.displays.first(where: { $0.displayID == display }) else {
        return nil
      }
      // visible wallpaper on Sonoma+ is owned by WindowManager with title
      // "Wallpaper". Backstop and offscreen agent windows show as placeholder
      // or black and must be skipped.
      let scrBounds = CGDisplayBounds(display)
      let wallpaperWindows = content.windows.filter { w in
        guard w.frame.intersects(scrBounds) else { return false }
        let bid = w.owningApplication?.bundleIdentifier ?? ""
        return bid == "com.apple.WindowManager" && (w.title ?? "") == "Wallpaper"
      }
      let filter: SCContentFilter
      if wallpaperWindows.isEmpty {
        filter = SCContentFilter(display: scDisplay, excludingWindows: [])
      } else {
        filter = SCContentFilter(display: scDisplay, including: wallpaperWindows)
      }
      // capture must match the display aspect; otherwise SCK letterboxes
      // the frame and the normalised cropFraction no longer lines up with
      // the real screen.
      let scrFrame = CGDisplayBounds(display)
      let aspect = scrFrame.width / max(scrFrame.height, 1)
      let targetHeight = 200
      let targetWidth = max(1, Int((Double(targetHeight) * aspect).rounded()))
      let cfg = SCStreamConfiguration()
      cfg.width = targetWidth
      cfg.height = targetHeight
      cfg.showsCursor = false
      cfg.capturesAudio = false
      let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: cfg)
      let cropped = cropToFraction(image, fraction: cropFraction) ?? image
      return dominantColor(cgImage: cropped)
    } catch {
      return nil
    }
  }

  private static func cropToFraction(_ image: CGImage, fraction: CGRect) -> CGImage? {
    let w = CGFloat(image.width)
    let h = CGFloat(image.height)
    let rect = CGRect(
      x: max(0, fraction.minX * w),
      y: max(0, fraction.minY * h),
      width: max(1, min(w - fraction.minX * w, fraction.width * w)),
      height: max(1, min(h - fraction.minY * h, fraction.height * h))
    )
    return image.cropping(to: rect)
  }

  private static func dominantColor(cgImage: CGImage) -> NSColor? {
    // downscale into a 32x32 sRGB buffer; CGContext handles colorspace
    // conversion for us so the bytes are directly comparable in sRGB.
    let side = 32
    let bytesPerRow = side * 4
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard
      let ctx = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let data = ctx.data else { return nil }
    let px = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

    // 24 hue bins. each pixel contributes its chroma (s) to its bin so
    // highly saturated minority pixels (a rust bridge against grey sky)
    // can out vote washed grey majorities. we keep the full pixel list
    // per winning bin so we can take the median hue pixel at the end,
    // which avoids averaging bluish and reddish members of the same wide
    // bin into brown.
    let bins = 24
    var weight = [Double](repeating: 0, count: bins)
    var members: [[(h: Double, s: Double, l: Double, r: Double, g: Double, b: Double)]] =
      Array(repeating: [], count: bins)
    for i in 0..<(side * side) {
      let r = Double(px[i * 4]) / 255.0
      let g = Double(px[i * 4 + 1]) / 255.0
      let b = Double(px[i * 4 + 2]) / 255.0
      let hsl = rgbToHsl(r: r, g: g, b: b)
      if hsl.s < 0.18 { continue }
      // down weight extremes so pure black and near white never dominate.
      let lightnessWeight: Double
      switch hsl.l {
      case ..<0.12, 0.88...: lightnessWeight = 0.15
      default: lightnessWeight = 1.0
      }
      let bin = min(bins - 1, Int(hsl.h * Double(bins)))
      weight[bin] += hsl.s * lightnessWeight
      members[bin].append((hsl.h, hsl.s, hsl.l, r, g, b))
    }
    guard let topBin = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[topBin] > 0
    else {
      // image is essentially grey; return the overall average so we at
      // least follow the wallpaper lightness.
      return averageColor(px: px, count: side * side)
    }
    let group = members[topBin].sorted { $0.s > $1.s }
    // take the median by saturation; the top of the sort would latch
    // onto a single highly saturated outlier (e.g. a reflection pixel).
    let pick = group[group.count / 2]
    return NSColor(srgbRed: pick.r, green: pick.g, blue: pick.b, alpha: 1)
  }

  private static func averageColor(
    px: UnsafeMutablePointer<UInt8>, count: Int
  ) -> NSColor? {
    var r = 0.0
    var g = 0.0
    var b = 0.0
    for i in 0..<count {
      r += Double(px[i * 4])
      g += Double(px[i * 4 + 1])
      b += Double(px[i * 4 + 2])
    }
    let n = Double(count) * 255.0
    return NSColor(srgbRed: r / n, green: g / n, blue: b / n, alpha: 1)
  }
}

struct HSL {
  let h: Double
  let s: Double
  let l: Double
}

func rgbToHsl(_ color: NSColor) -> HSL {
  let c = color.usingColorSpace(.sRGB) ?? color
  return rgbToHsl(
    r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
}

func rgbToHsl(r: Double, g: Double, b: Double) -> HSL {
  let mx = max(r, g, b)
  let mn = min(r, g, b)
  let l = (mx + mn) / 2.0
  if mx == mn { return HSL(h: 0, s: 0, l: l) }
  let d = mx - mn
  let s = l > 0.5 ? d / (2.0 - mx - mn) : d / (mx + mn)
  var h: Double
  switch mx {
  case r: h = (g - b) / d + (g < b ? 6.0 : 0.0)
  case g: h = (b - r) / d + 2.0
  default: h = (r - g) / d + 4.0
  }
  h /= 6.0
  return HSL(h: h, s: s, l: l)
}

func hslToNsColor(h: Double, s: Double, l: Double) -> NSColor {
  if s == 0 {
    return NSColor(srgbRed: l, green: l, blue: l, alpha: 1)
  }
  let q = l < 0.5 ? l * (1.0 + s) : l + s - l * s
  let p = 2.0 * l - q
  func hue(_ t: Double) -> Double {
    var t = t
    if t < 0 { t += 1 }
    if t > 1 { t -= 1 }
    if t < 1.0 / 6.0 { return p + (q - p) * 6.0 * t }
    if t < 1.0 / 2.0 { return q }
    if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6.0 }
    return p
  }
  return NSColor(
    srgbRed: hue(h + 1.0 / 3.0), green: hue(h), blue: hue(h - 1.0 / 3.0), alpha: 1)
}
