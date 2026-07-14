import SwiftUI

enum UsageLevel {
    case healthy, warning, critical

    // 阈值基于剩余额度：>=50% 绿、20-50% 琥珀、<20% 红（与 ClaudeBar 一致）
    static func level(usedPercent: Double) -> UsageLevel {
        let remaining = 100 - usedPercent
        if remaining < 20 { return .critical }
        if remaining < 50 { return .warning }
        return .healthy
    }
}

enum UsageFormat {
    static func tokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000_000 { return String(format: "%.1fB", Double(tokens) / 1_000_000_000) }
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fK", Double(tokens) / 1_000) }
        return "\(tokens)"
    }
}

struct PanelTheme {
    let dark: Bool

    init(_ scheme: ColorScheme) { dark = scheme == .dark }

    var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: dark
                ? [Color(red: 0.12, green: 0.08, blue: 0.22),
                   Color(red: 0.18, green: 0.10, blue: 0.28),
                   Color(red: 0.22, green: 0.12, blue: 0.32)]
                : [Color(red: 0.98, green: 0.96, blue: 1.00),
                   Color(red: 0.96, green: 0.94, blue: 0.99),
                   Color(red: 0.94, green: 0.92, blue: 0.98)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var cardGradient: LinearGradient {
        LinearGradient(
            colors: dark ? [.white.opacity(0.18), .white.opacity(0.08)]
                         : [.white.opacity(0.95), .white.opacity(0.85)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var glassBackground: Color { dark ? .white.opacity(0.12) : .white.opacity(0.8) }
    var glassBorder: Color {
        dark ? .white.opacity(0.25) : Color(red: 0.55, green: 0.32, blue: 0.85).opacity(0.15)
    }
    var textPrimary: Color { dark ? .white.opacity(0.95) : Color(red: 0.15, green: 0.12, blue: 0.22) }
    var textSecondary: Color { dark ? .white.opacity(0.70) : Color(red: 0.35, green: 0.32, blue: 0.42) }
    var textTertiary: Color { dark ? .white.opacity(0.50) : Color(red: 0.55, green: 0.52, blue: 0.62) }
    var progressTrack: Color {
        dark ? .white.opacity(0.15) : Color(red: 0.38, green: 0.22, blue: 0.72).opacity(0.1)
    }

    var statusHealthy: Color {
        dark ? Color(red: 0.35, green: 0.92, blue: 0.68) : Color(red: 0.22, green: 0.78, blue: 0.55)
    }
    var statusWarning: Color {
        dark ? Color(red: 0.98, green: 0.72, blue: 0.35) : Color(red: 0.92, green: 0.62, blue: 0.22)
    }
    var statusCritical: Color {
        dark ? Color(red: 0.98, green: 0.42, blue: 0.52) : Color(red: 0.92, green: 0.32, blue: 0.42)
    }

    var accentGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.98, green: 0.55, blue: 0.45), Color(red: 0.85, green: 0.35, blue: 0.65)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    func statusColor(usedPercent: Double) -> Color {
        switch UsageLevel.level(usedPercent: usedPercent) {
        case .healthy: return statusHealthy
        case .warning: return statusWarning
        case .critical: return statusCritical
        }
    }

    func progressGradient(usedPercent: Double) -> LinearGradient {
        let color = statusColor(usedPercent: usedPercent)
        return LinearGradient(colors: [color.opacity(0.8), color],
                              startPoint: .leading, endPoint: .trailing)
    }

    static func claudeColor(dark: Bool) -> Color {
        dark ? Color(red: 0.98, green: 0.55, blue: 0.45) : Color(red: 0.95, green: 0.48, blue: 0.38)
    }
    static func codexColor(dark: Bool) -> Color {
        dark ? Color(red: 0.35, green: 0.85, blue: 0.78) : Color(red: 0.18, green: 0.72, blue: 0.68)
    }
}
