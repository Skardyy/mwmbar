import SwiftUI

enum BarConfig {
  static let iconSize: CGFloat = 16
  static let iconGap: CGFloat = 3

  static let focusedOpacity: Double = 1.0
  static let inactiveOpacity: Double = 0.6
  static let hiddenOpacity: Double = 0.4

  static let focusedScale: CGFloat = 1.10
  static let hoverIconBoost: Double = 0.15

  static let containerCorner: CGFloat = 8
  static let pillCorner: CGFloat = 6

  static let activeFill: Color = Color.accentColor.opacity(0.22)
  static let activeStroke: Color = Color.accentColor.opacity(0.9)
  static let activePillScale: CGFloat = 1.04

  static let hoverFill: Color = .white.opacity(0.10)
  static let hoverActiveFill: Color = Color.accentColor.opacity(0.35)

  static let containerStroke: Color = .white.opacity(0.15)

  static let hiddenBadgeFill: Color = Color(red: 0.90, green: 0.15, blue: 0.15)
  static let hiddenBadgeStroke: Color = .black.opacity(0.5)

  static let focusedGlow: Color = Color.accentColor.opacity(0.75)

  static let transition: Animation = .spring(response: 0.28, dampingFraction: 0.85)
  static let hoverTransition: Animation = .easeInOut(duration: 0.12)
}
