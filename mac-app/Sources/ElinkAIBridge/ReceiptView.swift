import AppKit
import SwiftUI

/// 小票纸面。颜色固定为热敏纸的米白与墨黑，不跟随面板主题——它模拟的是一张实物。
struct ReceiptPaper: View {
    let receipt: UsageReceipt
    /// 开了集群时费用与 token 是全集群的，会话数却只能数本机的 transcript
    var sessionsLocalOnly = false
    /// 顶边已沿切刀撕开的比例（0 = 还整条连在出纸口上，1 = 已撕下），
    /// 从 `tearFromRight` 那一侧量起；撕开的那段是手撕毛边
    var torn: CGFloat = 0
    var tearFromRight = false
    /// 撕口形状的种子，与出纸口残边共用
    var tearSeed: UInt64 = 0

    static let width: CGFloat = 300
    static let paper = Color(red: 0.957, green: 0.945, blue: 0.918)
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.11)
    static let faint = Color(red: 0.42, green: 0.42, blue: 0.40)

    var body: some View {
        ReceiptContent(receipt: receipt, sessionsLocalOnly: sessionsLocalOnly)
            .equatable()
            .clipShape(ReceiptEdge(torn: torn, fromRight: tearFromRight, seed: tearSeed))
    }

    static func title(_ range: StatsRange) -> String {
        switch range {
        case .day: return tr("每日 AI 对账单", "DAILY AI RECEIPT")
        case .week: return tr("7 日 AI 对账单", "7-DAY AI RECEIPT")
        case .month: return tr("30 日 AI 对账单", "30-DAY AI RECEIPT")
        case .year: return tr("年度 AI 对账单", "ANNUAL AI RECEIPT")
        }
    }

    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: tr("zh_CN", "en_US"))
        f.timeZone = StatusService.aggregationCalendar.timeZone
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    static func periodText(_ receipt: UsageReceipt) -> String {
        switch receipt.range {
        case .day:
            return formatter("yMMMd").string(from: receipt.issuedAt)
        case .week, .month:
            let f = formatter("MMMd")
            return "\(f.string(from: receipt.start)) – \(f.string(from: receipt.issuedAt))"
        case .year:
            let f = formatter("yMMM")
            return "\(f.string(from: receipt.start)) – \(f.string(from: receipt.issuedAt))"
        }
    }

    static func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = StatusService.aggregationCalendar.timeZone
        return f.string(from: date)
    }

    static func serial(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        f.timeZone = StatusService.aggregationCalendar.timeZone
        return f.string(from: date)
    }
}

/// 纸面上的字。撕拉时每一帧在变的只有纸的外形，字是不变的：拆出来并按 Equatable 比较，
/// 拖动时 SwiftUI 就跳过这几十行的重排，也不用每次重建日期格式器。
private struct ReceiptContent: View, Equatable {
    let receipt: UsageReceipt
    let sessionsLocalOnly: Bool

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 3) {
                Text(ReceiptPaper.title(receipt.range))
                    .font(mono(20, .heavy))
                    .tracking(2)
                Text("Elink AI · Usage Receipt")
                    .font(mono(8))
                    .foregroundStyle(ReceiptPaper.faint)
            }
            .padding(.top, 16)
            VStack(spacing: 3) {
                row(tr("日期", "Date"), ReceiptPaper.periodText(receipt))
                row(tr("出单时间", "Issued"), ReceiptPaper.timeText(receipt.issuedAt))
                row(tr("单号", "No."), ReceiptPaper.serial(receipt.issuedAt))
            }
            dashes
            VStack(spacing: 3) {
                Text(tr("API 总费用", "API TOTAL"))
                    .font(mono(9, .semibold))
                    .tracking(3)
                Text("US" + UsageFormat.money(receipt.totalCost))
                    .font(mono(38, .black))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(tr("API 等价估算 · 非实际账单", "API-equivalent estimate · not a bill"))
                    .font(mono(8))
                    .foregroundStyle(ReceiptPaper.faint)
            }
            dashes
            VStack(spacing: 6) {
                HStack {
                    Text(tr("客户端 / 模型", "Client / Model"))
                    Spacer()
                    Text(tr("费用", "Cost"))
                }
                .font(mono(9))
                .foregroundStyle(ReceiptPaper.faint)
                if receipt.clients.isEmpty {
                    Text(tr("本期没有用量", "No usage in this period"))
                        .font(mono(10))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(receipt.clients, id: \.provider) { client in
                    VStack(spacing: 3) {
                        HStack(spacing: 6) {
                            PixelPetView(art: client.provider == "claude" ? PixelPet.claude
                                              : client.provider == "gemini" ? PixelPet.gemini
                                              : PixelPet.codex,
                                         color: ReceiptPaper.ink)
                                .frame(width: 16, height: 12)
                            Text(client.name.uppercased())
                                .font(mono(11, .heavy))
                            Spacer()
                            // 全部模型都没定价时写 0 会被读成「免费」
                            Text(client.lines.allSatisfy { $0.cost == nil }
                                 ? tr("未定价", "UNPRICED")
                                 : "US" + UsageFormat.money(client.cost, cents: true))
                                .font(mono(11, .heavy))
                        }
                        ForEach(client.lines, id: \.model) { line in
                            HStack {
                                Text(line.model.uppercased())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(line.cost.map { "US" + UsageFormat.money($0, cents: true) }
                                     ?? tr("未定价", "UNPRICED"))
                            }
                            .font(mono(9))
                            .padding(.leading, 22)
                        }
                    }
                }
            }
            dashes
            VStack(spacing: 3) {
                row(tr("总 Token 数", "Total tokens"), UsageFormat.tokens(receipt.totalTokens))
                row(tr("输入", "Input"), UsageFormat.tokens(receipt.input))
                row(tr("输出", "Output"), UsageFormat.tokens(receipt.output))
                row(tr("缓存命中率", "Cache hit rate"),
                    receipt.cacheHitRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                row(sessionsLocalOnly ? tr("本机会话数", "Sessions (this Mac)") : tr("会话数", "Sessions"),
                    receipt.sessions.map(String.init) ?? "…")
            }
            if receipt.coverage < 0.995 || !receipt.unpriced.isEmpty {
                VStack(spacing: 2) {
                    if receipt.coverage < 0.995 {
                        Text(tr("* 分类明细仅覆盖 \(Int((receipt.coverage * 100).rounded()))% 的 token，实际金额更高",
                                "* Breakdown covers \(Int((receipt.coverage * 100).rounded()))% of tokens; real cost is higher"))
                    }
                    if !receipt.unpriced.isEmpty {
                        Text(tr("* 未定价模型未计入总费用", "* Unpriced models are excluded from the total"))
                    }
                }
                .font(mono(7.5))
                .foregroundStyle(ReceiptPaper.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            dashes
            VStack(spacing: 4) {
                Text(tr("Elink AI Bridge · 菜单栏里的 AI 用量", "Elink AI Bridge · AI usage in your menu bar"))
                    .font(mono(8))
                Text(tr("谢谢惠顾，明天继续创造。", "Thank you. Keep building."))
                    .font(mono(10, .heavy))
                    .padding(.top, 4)
                Text(tr("—  顾客留存联  —", "—  CUSTOMER COPY  —"))
                    .font(mono(9, .semibold))
                    .tracking(1)
            }
            .padding(.bottom, 18)
        }
        .foregroundStyle(ReceiptPaper.ink)
        .padding(.horizontal, 20)
        .frame(width: ReceiptPaper.width)
        .background(ReceiptPaper.paper)
    }

    private func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).fontWeight(.semibold)
        }
        .font(mono(10))
    }

    private var dashes: some View {
        Line()
            .stroke(ReceiptPaper.faint.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(height: 1)
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}


/// 手撕的毛边：纸纤维被扯断的地方，齿距、深浅都不规则，整条线还带一点起伏。
///
/// 用种子生成：同一次出纸里，纸身的上边和留在出纸口的残边取同一条线，
/// 两边才严丝合缝；每次出纸换一个种子，每张的撕口都不一样。
enum TornEdge {
    /// 撕口的最大深度（pt）
    static let depth: CGFloat = 5

    /// 从左到右的撕口，y 落在 [0, depth]
    static func line(width: CGFloat, seed: UInt64) -> [CGPoint] {
        var rng = SplitMix64(seed: seed)
        let phase1 = rng.unit() * .pi * 2
        let phase2 = rng.unit() * .pi * 2
        var points: [CGPoint] = []
        var x: CGFloat = 0
        while x < width {
            let t = x / max(1, width)
            // 两段低频起伏让整条线不是直的，再叠上纤维级的细碎抖动
            let drift = 1.1 * sin(t * .pi * 2 * 1.3 + phase1) + 0.7 * sin(t * .pi * 2 * 3.7 + phase2)
            var fiber = (rng.unit() - 0.5) * 2.2
            // 偶尔扯出一根长一点的纤维
            if rng.unit() < 0.08 { fiber += rng.unit() * 2.4 }
            let y = min(depth, max(0, depth / 2 + drift + fiber))
            points.append(CGPoint(x: x, y: y))
            x += 1.2 + rng.unit() * 3.8
        }
        points.append(CGPoint(x: width, y: points.last?.y ?? depth / 2))
        return points
    }

    /// 撕到一半：撕开的那段跟撕口走，没撕开的那段取 `untornY`
    static func partial(_ line: [CGPoint], width: CGFloat, torn: CGFloat, fromRight: Bool,
                        untornY: CGFloat) -> [CGPoint] {
        let tip = fromRight ? width * (1 - torn) : width * torn
        return line.map { point in
            let isTorn = torn > 0 && (fromRight ? point.x >= tip : point.x <= tip)
            return CGPoint(x: point.x, y: isTorn ? point.y : untornY)
        }
    }
}

/// 可复现的伪随机数：撕口只要看起来随机，但同一个种子必须每次画得一模一样
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// [0, 1)
    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }
}

/// 小票外形：底边是上一张被撕走时留下的毛边；顶边撕开的那段是这次的撕口，其余仍是直边。
struct ReceiptEdge: Shape {
    var torn: CGFloat = 0
    var fromRight = false
    var seed: UInt64 = 0

    var animatableData: CGFloat {
        get { torn }
        set { torn = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let top = TornEdge.partial(TornEdge.line(width: rect.width, seed: seed), width: rect.width,
                                   torn: torn, fromRight: fromRight, untornY: 0)
        let bottom = TornEdge.line(width: rect.width, seed: seed &+ 0x5EED)
        return Path { p in
            p.addLines(top)
            for point in bottom.reversed() {
                p.addLine(to: CGPoint(x: point.x, y: rect.maxY - point.y))
            }
            p.closeSubpath()
        }
    }
}

/// 挂在出纸口下面的那一截纸：上边在出纸口里，下边在撕开的地方是撕口，
/// 与纸身的上边是同一条线。
private struct ReceiptStub: Shape {
    var torn: CGFloat
    var fromRight: Bool
    var seed: UInt64
    /// 撕口以上的直段高度
    var length: CGFloat

    var animatableData: CGFloat {
        get { torn }
        set { torn = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let line = TornEdge.partial(TornEdge.line(width: rect.width, seed: seed), width: rect.width,
                                    torn: torn, fromRight: fromRight, untornY: TornEdge.depth)
        return Path { p in
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: rect.maxX, y: 0))
            for point in line.reversed() {
                p.addLine(to: CGPoint(x: point.x, y: length + point.y))
            }
            p.closeSubpath()
        }
    }
}

struct ReceiptView: View {
    let theme: PanelTheme
    let clusterEnabled: Bool
    var store: UsageStore = .shared
    let onBack: () -> Void

    private enum Phase { case printing, ready, detached, settled }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var range: StatsRange = .day
    @State private var receipt: UsageReceipt?
    @State private var paperHeight: CGFloat = 520
    @State private var phase: Phase = .printing
    @State private var printTask: Task<Void, Never>?
    @State private var tear = TearState()
    @State private var shareImage: NSImage?
    @State private var sharePNG: Data?
    @State private var savedURL: URL?
    @State private var exportFailed = false
    @State private var copied = false

    /// 拉多远撕断
    static let tearDistance: CGFloat = 130
    /// 撕到底时纸绕撕口转过的角度
    static let maxTearAngle: Double = 14
    /// 撕开的比例：往下或斜着往一侧拉的距离；往上推不算
    static func tearProgress(_ drag: CGSize) -> CGFloat {
        min(1, hypot(drag.width, max(0, drag.height)) / tearDistance)
    }

    /// 撕口推进到的位置。往右拉时左侧先受力，从左边撕起；往左拉则反过来
    static func tearTip(progress: CGFloat, fromRight: Bool,
                        width: CGFloat = ReceiptPaper.width) -> CGFloat {
        fromRight ? width * (1 - progress) : width * progress
    }

    /// 纸绕撕口转动的角度（顺时针为正）。从左撕时左边先掉下去，是逆时针
    static func tearAngle(progress: CGFloat, fromRight: Bool) -> Double {
        (fromRight ? 1 : -1) * Double(progress) * maxTearAngle
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            GeometryReader { geo in
                stage(size: geo.size)
                    .overlay(alignment: .bottom) { if phase == .settled { deliveryNote } }
            }
            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { load() }
        .onDisappear { printTask?.cancel() }
        .onChange(of: range) { value in
            Log.user("change receipt range to \(value.rawValue)")
            load()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            PillButton(title: tr("返回", "Back"), icon: "chevron.left", theme: theme, action: onBack)
            Image(systemName: "printer")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Text(tr("对账单", "Receipt"))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Picker("", selection: $range) {
                ForEach(StatsRange.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            if phase == .settled {
                shareButton
                PillButton(title: copied ? tr("已复制", "Copied") : tr("复制图片", "Copy Image"),
                           icon: copied ? "checkmark" : "doc.on.doc", theme: theme) {
                    Log.user("copy usage receipt image")
                    copied = copyToPasteboard()
                }
                if let savedURL {
                    PillButton(title: tr("访达", "Finder"), icon: "folder", theme: theme) {
                        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
                    }
                }
                Spacer()
                PillButton(title: tr("再出一张", "Print again"), icon: "printer", theme: theme) {
                    Log.user("reprint usage receipt")
                    startPrint()
                }
            } else {
                Image(systemName: "hand.draw")
                    .foregroundStyle(theme.textTertiary)
                Text(phase == .printing
                     ? tr("正在出票…", "Printing…")
                     : tr("按住小票往下或斜着往一侧拉，沿切刀撕下来",
                          "Pull the receipt down or off to one side to tear it along the cutter"))
                    .foregroundStyle(theme.textTertiary)
                Spacer()
            }
        }
        .font(.system(size: 9, weight: .medium))
        .frame(height: 24)
    }

    /// 撕下后在纸下方说一声图片去了哪里
    @ViewBuilder
    private var deliveryNote: some View {
        HStack(spacing: 4) {
            if savedURL != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.statusHealthy)
                Text(tr("已复制到剪贴板，并保存到「下载」", "Copied to clipboard and saved to Downloads"))
            } else if exportFailed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.statusWarning)
                Text(tr("小票图片保存失败", "Couldn't save the receipt image"))
            }
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(theme.textSecondary)
        .transition(.opacity)
    }

    // MARK: 出纸与撕拉

    private func stage(size: CGSize) -> some View {
        ReceiptTearStage(receipt: receipt, sessionsLocalOnly: clusterEnabled, state: tear,
                         attached: phase == .printing || phase == .ready,
                         showStub: receipt != nil, size: size,
                         paperHeight: $paperHeight, gesture: tearGesture) { inside in
            guard phase == .ready else { return }
            (inside ? NSCursor.openHand : NSCursor.arrow).set()
        }
    }

    /// 手势始终挂着、由阶段决定怎么处理：中途换掉手势会打断正在进行的拖拽
    private var tearGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                switch phase {
                case .ready:
                    // 撕口还没成形时才定方向，撕开以后不再左右翻转
                    if Self.tearProgress(tear.drag) < 0.1 { tear.fromRight = value.translation.width < -2 }
                    tear.drag = value.translation
                    NSCursor.closedHand.set()
                    if Self.tearProgress(value.translation) >= 1 { detach(at: value.translation) }
                case .detached:
                    tear.drag = value.translation
                default:
                    break
                }
            }
            .onEnded { value in
                switch phase {
                case .ready:
                    let throwDistance = hypot(value.predictedEndTranslation.width - value.translation.width,
                                              value.predictedEndTranslation.height - value.translation.height)
                    if Self.tearProgress(value.predictedEndTranslation) >= 1, throwDistance > 60 {
                        // 一甩就断
                        detach(at: value.translation)
                        settle()
                    } else {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { tear.drag = .zero }
                        NSCursor.openHand.set()
                    }
                case .detached:
                    settle()
                default:
                    break
                }
            }
    }

    private func detach(at translation: CGSize) {
        Log.user("tear off usage receipt (\(range.rawValue))")
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        tear.detachDrag = translation
        tear.detachAngle = Self.tearAngle(progress: 1, fromRight: tear.fromRight)
        tear.drag = translation
        phase = .detached
        deliver()
    }

    /// 松手后像放在桌上一样落在出纸口下方，不会掉出面板；分享按钮随之出现
    private func settle() {
        NSCursor.arrow.set()
        guard !reduceMotion else {
            tear.resting = true
            phase = .settled
            return
        }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.68)) {
            tear.resting = true
            phase = .settled
        }
    }

    @ViewBuilder
    private var shareButton: some View {
        let title = ReceiptPaper.title(range)
        if let shareImage {
            let preview = SharePreview(title, image: Image(nsImage: shareImage))
            // 有文件就分享文件：隔空投送、邮件附件都要文件，拿到的也是原分辨率
            if let savedURL {
                ShareLink(item: savedURL, preview: preview) { shareLabel }
                    .buttonStyle(.plain)
            } else {
                ShareLink(item: Image(nsImage: shareImage), preview: preview) { shareLabel }
                    .buttonStyle(.plain)
            }
        }
    }

    private var shareLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.and.arrow.up").font(.system(size: 9, weight: .semibold))
            Text(tr("分享…", "Share…")).font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(theme.accentForeground)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Capsule().fill(theme.accentGradient))
    }

    // MARK: 导出

    /// 出纸完成就先渲染好：撕断那一下只剩写剪贴板和落盘，不会卡住手势
    private func prepareImage() {
        guard let receipt else { return }
        let paper = ReceiptPaper(receipt: receipt, sessionsLocalOnly: clusterEnabled, torn: 1,
                                 tearSeed: tear.seed)
            .padding(24)
        let renderer = ImageRenderer(content: paper)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        shareImage = image
        sharePNG = png
    }

    /// 撕下即交付：复制到剪贴板，并存一份到「下载」
    private func deliver() {
        guard let receipt else { return }
        if sharePNG == nil { prepareImage() }
        guard let png = sharePNG, copyToPasteboard() else {
            exportFailed = true
            return
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let url = downloads.appendingPathComponent(
            "elink-ai-receipt-\(ReceiptPaper.serial(receipt.issuedAt)).png")
        do {
            try png.write(to: url, options: .atomic)
            savedURL = url
        } catch {
            Log.warning("save receipt image failed: \(error.localizedDescription)", category: "receipt")
            exportFailed = true
        }
    }

    private func copyToPasteboard() -> Bool {
        guard let png = sharePNG, let tiff = shareImage?.tiffRepresentation else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        pasteboard.setData(png, forType: .png)
        pasteboard.setData(tiff, forType: .tiff)
        return true
    }

    private func load() {
        let range = range
        let store = store
        let now = Date()
        let since = StatusService.dayKey(UsageReceipt.windowStart(range: range, now: now))
        let home = FileManager.default.homeDirectoryForCurrentUser
        DispatchQueue.global(qos: .userInitiated).async {
            var usage: [String: [DailyModelUsage]] = [:]
            var categories: [String: [ModelCategoryUsage]] = [:]
            for (key, _) in UsageReceipt.providers {
                usage[key] = store.usage(provider: key, since: since)
                categories[key] = store.modelCategoryUsage(provider: key, since: since)
            }
            let sessions = UsageReceipt.sessionCount(
                since: UsageReceipt.windowStart(range: range, now: now),
                claudeRoot: home.appendingPathComponent(".claude/projects"),
                codexRoot: home.appendingPathComponent(".codex/sessions"))
            let result = UsageReceipt.make(range: range, now: now, usage: usage,
                                           modelCategories: categories, sessions: sessions)
            DispatchQueue.main.async {
                // 读库期间又切了范围：丢掉过期结果
                guard range == self.range else { return }
                receipt = result
                startPrint()
            }
        }
    }

    /// 出纸时长
    static let printDuration: TimeInterval = 1.4

    /// 走纸：一段连续动画匀速吐出来，末尾放缓停下。
    ///
    /// 不再分步一顿一顿地走：停顿在屏幕上读出来就是掉帧，每一步还要把整张小票重算一遍。
    private func startPrint() {
        printTask?.cancel()
        phase = .printing
        tear.seed = UInt64.random(in: 1...UInt64.max)
        tear.drag = .zero
        tear.fromRight = false
        tear.resting = false
        shareImage = nil
        sharePNG = nil
        savedURL = nil
        exportFailed = false
        copied = false
        tear.printProgress = 0
        guard !reduceMotion else {
            tear.printProgress = 1
            phase = .ready
            prepareImage()
            return
        }
        printTask = Task { @MainActor in
            // 先让纸缩回出纸口的那一帧画出来，动画才有起点；重新出纸时尤其如此，
            // 否则 1 → 0 → 1 在同一帧里抵消，纸不会动
            try? await Task.sleep(nanoseconds: 80_000_000)
            if Task.isCancelled { return }
            withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: Self.printDuration)) {
                tear.printProgress = 1
            }
            // 渲染分享图会占住主线程，等纸走完再做，免得卡在出纸的最后一下
            try? await Task.sleep(nanoseconds: UInt64(Self.printDuration * 1_000_000_000))
            if Task.isCancelled { return }
            phase = .ready
            prepareImage()
        }
    }
}

/// 出纸与撕拉的全部可变状态。手势只改它，画面只读它——出纸区因此是
/// 这份状态的纯函数，测试可以直接摆出「撕到一半」来截图核对。
struct TearState: Equatable {
    /// 这一张的撕口形状，每次出纸换一个
    var seed: UInt64 = 0
    var printProgress: CGFloat = 0
    var drag: CGSize = .zero
    var fromRight = false
    /// 撕断那一刻的手势位移与倾角：之后纸完全跟手，从这里接着走
    var detachDrag: CGSize = .zero
    var detachAngle: Double = 0
    /// 已松手落定：位置由出纸区按自己的尺寸算出，保证整张留在面板里
    var resting = false
}

/// 出纸口 + 小票。整个区域按同一比例缩放，里面一律用未缩放的坐标：
/// 撕口的转轴、手势位移和纸的位置才能对得上。
struct ReceiptTearStage<G: Gesture>: View {
    let receipt: UsageReceipt?
    let sessionsLocalOnly: Bool
    let state: TearState
    /// 还连在出纸口上（出纸中或待撕）
    let attached: Bool
    let showStub: Bool
    let size: CGSize
    @Binding var paperHeight: CGFloat
    let gesture: G
    var onHoverPaper: (Bool) -> Void = { _ in }

    static var slotHeight: CGFloat { 14 }
    /// 切刀在出纸口下沿（多压 1pt 盖住接缝），残边和撕口都露在外面
    static var cutterY: CGFloat { slotHeight - 1 }
    /// 撕口在出纸口下方多远：这一截始终挂在外面，撕开时毛边才露得出来
    static var stubLength: CGFloat { 10 }

    var body: some View {
        let scale = min(1, max(0.5, (size.height - Self.cutterY - Self.stubLength - 8)
                                    / max(1, paperHeight)))
        let width = size.width / scale
        let height = size.height / scale
        return ZStack(alignment: .top) {
            paperLayer(width: width, height: height)
            slot
        }
        .frame(width: width, height: height, alignment: .top)
        .scaleEffect(scale, anchor: .top)
        .frame(width: size.width, height: size.height, alignment: .top)
        .onPreferenceChange(PaperHeightKey.self) { if $0 > 0 { paperHeight = $0 } }
    }

    private func paperLayer(width: CGFloat, height: CGFloat) -> some View {
        let progress = attached ? ReceiptView.tearProgress(state.drag) : 1
        return ZStack(alignment: .top) {
            if showStub {
                // 米白纸在浅色面板上几乎看不出来，靠一道描边和一点投影把残边勾出来
                let stub = ReceiptStub(torn: progress, fromRight: state.fromRight,
                                       seed: state.seed, length: Self.stubLength)
                stub.fill(ReceiptPaper.paper)
                    .overlay(stub.stroke(ReceiptPaper.faint.opacity(0.45), lineWidth: 0.6))
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                    .frame(width: ReceiptPaper.width, height: Self.stubLength + TornEdge.depth)
            }
            if let receipt {
                paper(receipt, progress: progress, stage: CGSize(width: width, height: height))
                    .padding(.top, Self.stubLength)
            }
        }
        .padding(.top, Self.cutterY)
        .frame(width: width, height: height, alignment: .top)
        // 只遮掉切刀以上：纸在机器里的部分看不见，往两侧歪、往下甩都不会被裁掉
        .mask(alignment: .top) {
            Rectangle()
                .frame(width: width + 1600, height: height + 3000)
                .offset(y: Self.cutterY)
        }
    }

    private func paper(_ receipt: UsageReceipt, progress: CGFloat, stage: CGSize) -> some View {
        let paperSize = CGSize(width: ReceiptPaper.width, height: paperHeight)
        var angle: Double
        let anchor: UnitPoint
        var offset = CGSize.zero
        var scale: CGFloat = 1
        if attached {
            // 还连着：绕撕口推进到的那一点转，撕开的一侧往下掉，裂口张开
            angle = ReceiptView.tearAngle(progress: progress, fromRight: state.fromRight)
            anchor = UnitPoint(x: ReceiptView.tearTip(progress: progress, fromRight: state.fromRight)
                                   / ReceiptPaper.width, y: 0)
        } else if state.resting {
            // 落定：整张摆在出纸口下方，微微歪着
            let pose = Self.restPose(stage: stage, paperSize: paperSize, fromRight: state.fromRight)
            angle = pose.angle
            scale = pose.scale
            offset = pose.offset
            anchor = UnitPoint(x: state.fromRight ? 0 : 1, y: 0)
        } else {
            // 已撕断、还捏在手里：从断开的那一角接着走，跟手；拖出面板边缘时被拉住
            let dx = state.drag.width - state.detachDrag.width
            angle = state.detachAngle + max(-12, min(12, Double(dx) / 25))
            anchor = UnitPoint(x: state.fromRight ? 0 : 1, y: 0)
            offset = Self.heldOffset(CGSize(width: dx, height: state.drag.height - state.detachDrag.height),
                                     angle: angle, stage: stage, paperSize: paperSize,
                                     fromRight: state.fromRight)
        }
        return ReceiptPaper(receipt: receipt, sessionsLocalOnly: sessionsLocalOnly,
                            torn: progress, tearFromRight: state.fromRight, tearSeed: state.seed)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { paper in
                Color.clear.preference(key: PaperHeightKey.self, value: paper.size.height)
            })
            .shadow(color: .black.opacity(attached ? 0.16 : 0.26), radius: attached ? 5 : 10,
                    y: attached ? 3 : 6)
            .scaleEffect(scale)
            .rotationEffect(.degrees(angle), anchor: anchor)
            .offset(x: offset.width, y: offset.height - (1 - state.printProgress) * paperHeight)
            .gesture(gesture)
            .onHover(perform: onHoverPaper)
    }

    // MARK: 撕下后的几何（出纸区内的未缩放坐标）

    /// 撕下后纸绕断开的那一角转，这一角在纸上的横坐标
    private static func cornerX(fromRight: Bool) -> CGFloat { fromRight ? 0 : ReceiptPaper.width }

    /// 纸的左上角：水平居中，顶边在残边下面
    private static func paperOrigin(stage: CGSize) -> CGPoint {
        CGPoint(x: (stage.width - ReceiptPaper.width) / 2, y: cutterY + stubLength)
    }

    /// 绕断角转 `angle`、再平移 `offset` 之后，纸的中心落在哪里。
    /// 以中心缩放不移动中心，所以落定时的缩放不影响这里。
    static func paperCenter(stage: CGSize, paperSize: CGSize, fromRight: Bool,
                            angle: Double, offset: CGSize) -> CGPoint {
        let origin = paperOrigin(stage: stage)
        let corner = cornerX(fromRight: fromRight)
        let cx = paperSize.width / 2 - corner, cy = paperSize.height / 2
        let radians = angle * .pi / 180
        return CGPoint(x: origin.x + corner + cx * cos(radians) - cy * sin(radians) + offset.width,
                       y: origin.y + cx * sin(radians) + cy * cos(radians) + offset.height)
    }

    /// 底部给「已复制…」那行字留的位置
    static var restBottomReserve: CGFloat { 26 }

    /// 落定的姿势：缩到放得下，中心摆在出纸口下方的空处，往撕开的那侧歪 4°
    static func restPose(stage: CGSize, paperSize: CGSize, fromRight: Bool)
        -> (angle: Double, scale: CGFloat, offset: CGSize) {
        let angle: Double = fromRight ? 4 : -4
        let top = cutterY + stubLength
        let room = max(1, stage.height - top - restBottomReserve)
        // 歪 4° 后外接框比纸本身高出一点，多留 24pt
        let scale = min(0.92, max(0.4, room / (paperSize.height + 24)))
        let target = CGPoint(x: stage.width / 2, y: top + room / 2)
        let center = paperCenter(stage: stage, paperSize: paperSize, fromRight: fromRight,
                                 angle: angle, offset: .zero)
        return (angle, scale, CGSize(width: target.x - center.x, height: target.y - center.y))
    }

    /// 捏在手里越出出纸区时最多再走这么远。出纸区外只剩页面与卡片的内边距
    /// （约 28pt），再多就会被窗口边缘裁掉
    static var maxOvershoot: CGFloat { 24 }

    /// 捏在手里时照常跟手，但纸中心越出面板后像被橡皮筋拽住：
    /// 越往外拉越拉不动，无论拖多远都只越界一小截，纸不会被拖出面板
    static func heldOffset(_ offset: CGSize, angle: Double, stage: CGSize, paperSize: CGSize,
                           fromRight: Bool) -> CGSize {
        let center = paperCenter(stage: stage, paperSize: paperSize, fromRight: fromRight,
                                 angle: angle, offset: offset)
        func resist(_ excess: CGFloat) -> CGFloat { maxOvershoot * (1 - exp(-excess / 120)) }
        func band(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            if value < low { return low - resist(low - value) }
            if value > high { return high + resist(value - high) }
            return value
        }
        let halfW = paperSize.width / 2, halfH = paperSize.height / 2
        let x = band(center.x, min(halfW, stage.width / 2), max(stage.width - halfW, stage.width / 2))
        let y = band(center.y, cutterY + stubLength + halfH,
                     max(cutterY + stubLength + halfH, stage.height - halfH))
        return CGSize(width: offset.width + x - center.x, height: offset.height + y - center.y)
    }

    /// 出纸口：深色机身上的一道缝，纸从缝里出来
    private var slot: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color(white: 0.12))
            .overlay(
                Capsule()
                    .fill(Color.black)
                    .frame(width: ReceiptPaper.width + 8, height: 3)
            )
            .frame(width: ReceiptPaper.width + 32, height: Self.slotHeight)
            .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
    }
}

private struct PaperHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
