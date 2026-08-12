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

    /// 金额。小额保留分位；超过 100 之后分位没有意义，取整更好读。
    /// 币种照接口给的那个显示——账号可能不是按美元计费的，写死 `$` 会把
    /// 一个欧元额度说成美元额度。
    static func money(_ value: Double, currency: String = "USD",
                      cents: Bool? = nil) -> String {
        let symbol = ["USD": "$", "EUR": "€", "GBP": "£", "JPY": "¥", "CNY": "¥"][currency]
        let amount = cents ?? (abs(value) < 100)
            ? String(format: "%.2f", value)
            : String(format: "%.0f", value)
        return symbol.map { $0 + amount } ?? "\(amount) \(currency)"
    }

    /// 积分。它不是钱，所以不带任何货币符号；整数就不写小数点，
    /// `1000.00 credits` 只会让人怀疑这到底是不是钱。
    static func credits(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded()
            ? String(format: "%.0f", rounded)
            : String(format: "%g", rounded)
    }

    /// 一个额度数，按它自己的单位渲染。`unit` 要么是 ISO 货币代码，要么是
    /// `credits`——Codex 的额度按积分计，给它加个 `$` 就是把积分说成美元。
    static func amount(_ value: Double, unit: String, cents: Bool? = nil) -> String {
        unit == ExtraUsage.creditsUnit
            ? credits(value)
            : money(value, currency: unit, cents: cents)
    }

    /// 「已用 / 上限」这一对。两个数必须同精度，否则 `$10.30 / $100` 读起来像是
    /// 哪一边算错了。金额一律保留分位：这是真金白银的扣款额，不是折算出来的
    /// 估值，估值那边的取整规则不适用。
    static func amountPair(_ used: Double, _ limit: Double, unit: String) -> String {
        "\(amount(used, unit: unit, cents: true)) / \(amount(limit, unit: unit, cents: true))"
    }
}

/// 一套主题在单一明暗模式下的全部颜色。
///
/// 面板里没有任何视图直接写颜色字面量，全部经 `PanelTheme` 读到这里——所以新增一套
/// 主题只是新写一个实现并登记进 `AppTheme`，不需要碰任何视图。反过来，这也意味着
/// 新增一个颜色语义必须在这里补齐所有实现，编译器会替我们守住「某个主题漏了一个色」。
protocol PanelPaletteSpec {
    /// 面板底的渐变停靠点，从左上到右下
    var backgroundStops: [Color] { get }
    /// 卡片底的渐变停靠点
    var cardStops: [Color] { get }
    var glassBackground: Color { get }
    var glassBorder: Color { get }
    var textPrimary: Color { get }
    var textSecondary: Color { get }
    var textTertiary: Color { get }
    var progressTrack: Color { get }

    var statusHealthy: Color { get }
    var statusWarning: Color { get }
    var statusCritical: Color { get }
    /// 「在线 / 进行中」这类中性强调。它不在绿黄红那条轴上：同步中既不是健康
    /// 也不是告警，用状态色会让人以为出了事。
    var statusInfo: Color { get }

    /// 按钮 hover 的填色，与压在它上面的前景色
    var accentStops: [Color] { get }
    var accentForeground: Color { get }

    /// 分段控件选中段的填色。它和 `accentStops` 不能共用：那是我们自己画的按钮，
    /// 前景色由 `accentForeground` 跟着翻转；分段控件是 AppKit 原生控件，
    /// 选中段的文字固定是白的，所以这个值在明暗两种模式下都必须能承白字。
    var controlAccent: Color { get }

    /// 延迟折线的单序列色。它是数据不是状态，必须和三个状态色分得开。
    var seriesColor: Color { get }

    var claudeColor: Color { get }
    var codexColor: Color { get }

    /// 堆叠条按模型着色的色位，按顺序取用
    var dataPalette: [Color] { get }
    /// 设备身份色。与模型配色分开，落在不同视觉位置，不会互相冒充。
    var devicePalette: [Color] { get }
    /// Token 分类色，顺序对应 输入 / 输出 / 缓存读取 / 缓存写入 / 推理
    var categoryPalette: [Color] { get }
}

// MARK: - 和纸墨

/// 「和纸墨」的基础色板：暖白的纸与黑灰的墨，中间只有暖灰过渡，没有第三个色相。
///
/// 六个值取自参考稿的 COLOR PALETTE。底色偏暖、文字中性是这套配色的关键：
/// 纸带黄调、墨不带任何色偏，两者叠在一起才是纸墨而不是「灰蓝界面」。
private enum Washi {
    static let ink = Color(red: 0.067, green: 0.067, blue: 0.067)    // #111111 墨
    static let sumi = Color(red: 0.200, green: 0.200, blue: 0.200)   // #333333 淡墨
    static let stone = Color(red: 0.467, green: 0.467, blue: 0.467)  // #777777 石
    static let clay = Color(red: 0.745, green: 0.722, blue: 0.678)   // #BEB8AD 砂灰
    static let sand = Color(red: 0.902, green: 0.882, blue: 0.843)   // #E6E1D7 砂
    static let paper = Color(red: 0.965, green: 0.957, blue: 0.933)  // #F6F4EE 纸
}

struct WashiPalette: PanelPaletteSpec {
    let dark: Bool

    /// 深色端没有取纯黑：#111111 留给文字和描边，底比它再亮一档，卡片才有地方浮起来。
    /// 三段之间只差几个百分点，渐变是要给 440pt 宽的面板一点方向感，不是要被看见。
    var backgroundStops: [Color] {
        dark ? [Color(red: 0.145, green: 0.139, blue: 0.126),
                Color(red: 0.122, green: 0.116, blue: 0.104),
                Color(red: 0.098, green: 0.094, blue: 0.086)]
             : [Washi.paper,
                Color(red: 0.945, green: 0.933, blue: 0.902),
                Washi.sand]
    }

    /// 卡片用半透明而不是实色：底下的纸/炭渐变透上来，卡片在面板顶部和底部就不是
    /// 同一个色，一层叠一层的关系读得出来。
    var cardStops: [Color] {
        dark ? [Washi.sand.opacity(0.10), Washi.sand.opacity(0.05)]
             : [.white.opacity(0.85), .white.opacity(0.62)]
    }

    var glassBackground: Color { dark ? Washi.sand.opacity(0.08) : .white.opacity(0.60) }
    var glassBorder: Color { dark ? Washi.clay.opacity(0.20) : Washi.clay.opacity(0.55) }
    var textPrimary: Color { dark ? Washi.paper.opacity(0.95) : Washi.ink }
    var textSecondary: Color { dark ? Washi.sand.opacity(0.72) : Washi.sumi }
    var textTertiary: Color { dark ? Washi.clay.opacity(0.55) : Washi.stone }
    var progressTrack: Color { dark ? Washi.clay.opacity(0.16) : Washi.clay.opacity(0.45) }

    /// 状态色是这套配色里仅有的三个色相，因此压到最低饱和：苔绿、山吹、弁柄。
    /// 三个值在纸底（或炭底）上都过了 4.2:1 ——它们要承载 8pt 的徽章文字，
    /// 而鲜艳的橙黄在纸上只有 2 点几，比这更难读。
    var statusHealthy: Color {
        dark ? Color(red: 0.58, green: 0.72, blue: 0.53) : Color(red: 0.31, green: 0.42, blue: 0.28)
    }
    var statusWarning: Color {
        dark ? Color(red: 0.85, green: 0.68, blue: 0.35) : Color(red: 0.60, green: 0.42, blue: 0.08)
    }
    var statusCritical: Color {
        dark ? Color(red: 0.87, green: 0.50, blue: 0.44) : Color(red: 0.66, green: 0.25, blue: 0.18)
    }
    var statusInfo: Color {
        dark ? Color(red: 0.60, green: 0.72, blue: 0.87) : Color(red: 0.24, green: 0.36, blue: 0.52)
    }

    /// 浅色模式压成墨、深色模式提到砂。参考稿里的进度条就是这么用的——底是砂、
    /// 填是纯墨，中间没有第三个色。前景随之反向，否则深色模式会变成浅底浅字。
    var accentStops: [Color] { dark ? [Washi.sand, Washi.clay] : [Washi.sumi, Washi.ink] }
    var accentForeground: Color { dark ? Washi.ink : Washi.paper }

    /// 深色模式不能直接用砂色：分段控件的白字会压在浅底上。取一档暖炭，
    /// 既比卡片底亮出选中感，又留得住白字。
    var controlAccent: Color {
        dark ? Color(red: 0.32, green: 0.30, blue: 0.27) : Washi.sumi
    }

    var seriesColor: Color { dark ? Washi.sand : Washi.sumi }

    /// 两个 provider 的身份色：柿与青磁。保留暖冷对立，只把饱和度收到能和纸墨共处。
    var claudeColor: Color {
        dark ? Color(red: 0.87, green: 0.55, blue: 0.42) : Color(red: 0.72, green: 0.36, blue: 0.24)
    }
    var codexColor: Color {
        dark ? Color(red: 0.52, green: 0.75, blue: 0.72) : Color(red: 0.24, green: 0.45, blue: 0.44)
    }

    /// 八个色位排在一起要互相分得开，因此保留通用色轮的八个色相，只统一降到
    /// 中明度低饱和——鲜艳的原色堆在纸底上会盖过内容，而堆叠条本身才是主角。
    var dataPalette: [Color] {
        [Color(red: 0.72, green: 0.40, blue: 0.28),  // 柿
         Color(red: 0.28, green: 0.50, blue: 0.48),  // 青磁
         Color(red: 0.48, green: 0.43, blue: 0.60),  // 藤
         Color(red: 0.29, green: 0.40, blue: 0.56),  // 藍
         Color(red: 0.72, green: 0.55, blue: 0.22),  // 山吹
         Color(red: 0.68, green: 0.42, blue: 0.48),  // 梅
         Color(red: 0.44, green: 0.54, blue: 0.34),  // 苔
         Color(red: 0.55, green: 0.53, blue: 0.49)]  // 鼠
    }

    var devicePalette: [Color] {
        [Color(red: 0.26, green: 0.34, blue: 0.52),  // 紺
         Color(red: 0.22, green: 0.47, blue: 0.42),  // 松
         Color(red: 0.66, green: 0.42, blue: 0.22),  // 赭
         Color(red: 0.50, green: 0.40, blue: 0.62),  // 桔梗
         Color(red: 0.32, green: 0.52, blue: 0.62),  // 浅葱
         Color(red: 0.62, green: 0.32, blue: 0.38)]  // 蘇芳
    }

    var categoryPalette: [Color] {
        [Color(red: 0.31, green: 0.44, blue: 0.62),
         Color(red: 0.36, green: 0.53, blue: 0.38),
         Color(red: 0.52, green: 0.44, blue: 0.64),
         Color(red: 0.74, green: 0.54, blue: 0.24),
         Color(red: 0.74, green: 0.38, blue: 0.30)]
    }
}

// MARK: - 紫夜

/// v0.1.20 之前的配色，作为可选项保留。
struct VioletPalette: PanelPaletteSpec {
    let dark: Bool

    var backgroundStops: [Color] {
        dark ? [Color(red: 0.12, green: 0.08, blue: 0.22),
                Color(red: 0.18, green: 0.10, blue: 0.28),
                Color(red: 0.22, green: 0.12, blue: 0.32)]
             : [Color(red: 0.98, green: 0.96, blue: 1.00),
                Color(red: 0.96, green: 0.94, blue: 0.99),
                Color(red: 0.94, green: 0.92, blue: 0.98)]
    }

    var cardStops: [Color] {
        dark ? [.white.opacity(0.18), .white.opacity(0.08)]
             : [.white.opacity(0.95), .white.opacity(0.85)]
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
    var statusInfo: Color {
        dark ? Color(red: 0.45, green: 0.68, blue: 1.00) : Color(red: 0.32, green: 0.58, blue: 0.96)
    }

    var accentStops: [Color] {
        [Color(red: 0.98, green: 0.55, blue: 0.45), Color(red: 0.85, green: 0.35, blue: 0.65)]
    }
    var accentForeground: Color { .white }

    /// 这套主题原本就用系统默认的分段控件，两种模式沿用同一个蓝。
    /// 不能直接取 statusInfo：它的深色取值是为了在深底上显字而提亮过的，
    /// 拿来做填色反而压不住白字。
    var controlAccent: Color { Color(red: 0.28, green: 0.52, blue: 0.92) }

    var seriesColor: Color {
        dark ? Color(red: 0.60, green: 0.49, blue: 0.91) : Color(red: 0.48, green: 0.32, blue: 0.85)
    }

    var claudeColor: Color {
        dark ? Color(red: 0.98, green: 0.55, blue: 0.45) : Color(red: 0.95, green: 0.48, blue: 0.38)
    }
    var codexColor: Color {
        dark ? Color(red: 0.35, green: 0.85, blue: 0.78) : Color(red: 0.18, green: 0.72, blue: 0.68)
    }

    var dataPalette: [Color] {
        [Color(red: 0.98, green: 0.55, blue: 0.45),  // 珊瑚
         Color(red: 0.30, green: 0.76, blue: 0.71),  // 青绿
         Color(red: 0.58, green: 0.46, blue: 0.96),  // 紫
         Color(red: 0.36, green: 0.62, blue: 0.98),  // 蓝
         Color(red: 0.95, green: 0.68, blue: 0.28),  // 琥珀
         Color(red: 0.90, green: 0.42, blue: 0.68),  // 粉
         Color(red: 0.45, green: 0.80, blue: 0.38),  // 绿
         Color(red: 0.62, green: 0.60, blue: 0.68)]  // 灰
    }

    var devicePalette: [Color] {
        [Color(red: 0.35, green: 0.47, blue: 0.93),  // 靛蓝
         Color(red: 0.16, green: 0.68, blue: 0.60),  // 松绿
         Color(red: 0.86, green: 0.45, blue: 0.16),  // 赭橙
         Color(red: 0.72, green: 0.33, blue: 0.82),  // 紫罗兰
         Color(red: 0.22, green: 0.60, blue: 0.86),  // 天蓝
         Color(red: 0.83, green: 0.35, blue: 0.53)]  // 玫红
    }

    var categoryPalette: [Color] {
        [Color(red: 0.36, green: 0.62, blue: 0.98),
         Color(red: 0.30, green: 0.76, blue: 0.55),
         Color(red: 0.78, green: 0.38, blue: 0.92),
         Color(red: 0.95, green: 0.60, blue: 0.25),
         Color(red: 0.98, green: 0.38, blue: 0.45)]
    }
}

// MARK: - 主题选择

/// 面板主题。未显式选择时用「和纸墨」。
enum AppTheme: String, CaseIterable {
    case washi
    case violet

    static let defaultsKey = "elink_theme"

    static var current: AppTheme {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let value = AppTheme(rawValue: raw) else { return .washi }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var label: String {
        switch self {
        case .washi: return tr("和纸墨", "Washi")
        case .violet: return tr("紫夜", "Violet")
        }
    }

    func palette(dark: Bool) -> PanelPaletteSpec {
        switch self {
        case .washi: return WashiPalette(dark: dark)
        case .violet: return VioletPalette(dark: dark)
        }
    }
}

/// 视图取色的唯一入口。把「明暗模式」和「用户选的主题」合成一份具体色板，
/// 视图只认这一层，因此换主题不需要改任何视图。
struct PanelTheme {
    let dark: Bool
    private let palette: PanelPaletteSpec

    init(_ scheme: ColorScheme, _ theme: AppTheme = .current) {
        dark = scheme == .dark
        palette = theme.palette(dark: dark)
    }

    var backgroundGradient: LinearGradient {
        LinearGradient(colors: palette.backgroundStops,
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var cardGradient: LinearGradient {
        LinearGradient(colors: palette.cardStops,
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var accentGradient: LinearGradient {
        LinearGradient(colors: palette.accentStops,
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var glassBackground: Color { palette.glassBackground }
    var glassBorder: Color { palette.glassBorder }
    var textPrimary: Color { palette.textPrimary }
    var textSecondary: Color { palette.textSecondary }
    var textTertiary: Color { palette.textTertiary }
    var progressTrack: Color { palette.progressTrack }

    var statusHealthy: Color { palette.statusHealthy }
    var statusWarning: Color { palette.statusWarning }
    var statusCritical: Color { palette.statusCritical }
    var statusInfo: Color { palette.statusInfo }
    var accentForeground: Color { palette.accentForeground }
    var controlAccent: Color { palette.controlAccent }
    var seriesColor: Color { palette.seriesColor }

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

    static func claudeColor(dark: Bool) -> Color { AppTheme.current.palette(dark: dark).claudeColor }
    static func codexColor(dark: Bool) -> Color { AppTheme.current.palette(dark: dark).codexColor }
}
