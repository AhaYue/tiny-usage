import SwiftUI

extension Color {
    /// 0xRRGGBB → opaque sRGB colour.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// Day count of a quota window (e.g. 7 for weekly, 30 for monthly), from the window's total length.
///
/// Derived from the window's total length, never from how far the reset is — on day 27 of a
/// 30-day window the remaining time is 3 days, but the window is still a 30-day one.
/// Returns nil for session-length (<= 6h) or unknown windows, so callers can omit the badge
/// rather than print a wrong number.
func quotaWindowDays(_ windowSeconds: TimeInterval?) -> Int? {
    guard let windowSeconds, windowSeconds > 6 * 3600 else { return nil }
    return max(1, Int((windowSeconds / 86_400).rounded()))
}
