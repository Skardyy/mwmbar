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

  static let activeFill: Color = Color(red: 0.25, green: 0.35, blue: 0.55).opacity(0.55)
  static let activeStroke: Color = Color(red: 0.60, green: 0.75, blue: 0.95).opacity(0.60)
  static let activePillScale: CGFloat = 1.04

  static let hoverFill: Color = .white.opacity(0.10)
  static let hoverActiveFill: Color = Color(red: 0.31, green: 0.42, blue: 0.64).opacity(0.65)

  static let containerStroke: Color = Color(red: 0.60, green: 0.70, blue: 0.85).opacity(0.35)

  static let hiddenBadgeFill: Color = Color(red: 0.85, green: 0.10, blue: 0.10).opacity(0.85)
  static let hiddenBadgeStroke: Color = .black.opacity(0.5)

  static let focusedGlow: Color = Color(red: 0.60, green: 0.75, blue: 0.95).opacity(0.55)

  static let transition: Animation = .spring(response: 0.28, dampingFraction: 0.85)
  static let hoverTransition: Animation = .easeInOut(duration: 0.12)
}
