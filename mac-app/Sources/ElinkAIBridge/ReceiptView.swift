import AppKit
import SwiftUI

/// 小票纸面。颜色固定为热敏纸的米白与墨黑，不跟随面板主题——它模拟的是一张实物。
struct ReceiptPaper: View {
    let receipt: UsageReceipt
    /// 开了集群时费用与 token 是全集群的，会话数却只能数本机的 transcript
    var sessionsLocalOnly = false
    /// 顶边已沿切刀撕开的比例（0 = 还整条连在出纸口上，1 = 已撕下），
    /// 从 `tearFromRight` 那一侧量起；撕开的那段是锯齿
    var torn: CGFloat = 0
    var tearFromRight = false

    static let width: CGFloat = 300
    static let paper = Color(red: 0.957, green: 0.945, blue: 0.918)
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.11)
    static let faint = Color(red: 0.42, green: 0.42, blue: 0.40)

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 3) {
                Text(Self.title(receipt.range))
                    .font(mono(20, .heavy))
                    .tracking(2)
                Text("Elink AI · Usage Receipt")
                    .font(mono(8))
                    .foregroundStyle(Self.faint)
            }
            .padding(.top, 16)
            VStack(spacing: 3) {
                row(tr("日期", "Date"), Self.periodText(receipt))
                row(tr("出单时间", "Issued"), Self.timeText(receipt.issuedAt))
                row(tr("单号", "No."), Self.serial(receipt.issuedAt))
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
                    .foregroundStyle(Self.faint)
            }
            dashes
            VStack(spacing: 6) {
                HStack {
                    Text(tr("客户端 / 模型", "Client / Model"))
                    Spacer()
                    Text(tr("费用", "Cost"))
                }
                .font(mono(9))
                .foregroundStyle(Self.faint)
                if receipt.clients.isEmpty {
                    Text(tr("本期没有用量", "No usage in this period"))
                        .font(mono(10))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(receipt.clients, id: \.provider) { client in
                    VStack(spacing: 3) {
                        HStack(spacing: 6) {
                            PixelPetView(art: client.provider == "claude" ? PixelPet.claude : PixelPet.codex,
                                         color: Self.ink)
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
                .foregroundStyle(Self.faint)
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
        .foregroundStyle(Self.ink)
        .padding(.horizontal, 20)
        .frame(width: Self.width)
        .background(Self.paper)
        .clipShape(ReceiptEdge(torn: torn, fromRight: tearFromRight))
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
            .stroke(Self.faint.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(height: 1)
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

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}


/// 小票外形：底边始终是切刀留下的锯齿；顶边撕开的那段也是锯齿，其余仍是直边。
struct ReceiptEdge: Shape {
    var torn: CGFloat = 0
    var fromRight = false
    var tooth: CGFloat = 6

    var animatableData: CGFloat {
        get { torn }
        set { torn = newValue }
    }

    /// 沿切刀的那条线，从左到右。撕开的部分是锯齿（峰在 0、谷在齿深），
    /// 没撕开的部分取 `untornY`。纸身和留在出纸口的残边共用这条线，齿正好咬合。
    static func cutLine(width: CGFloat, torn: CGFloat, fromRight: Bool,
                        tooth: CGFloat, untornY: CGFloat) -> [CGPoint] {
        let count = max(1, Int(width / tooth))
        let step = width / CGFloat(count)
        let depth = tooth * 0.6
        let tip = fromRight ? width * (1 - torn) : width * torn
        return (0...(2 * count)).map { i in
            let x = step * CGFloat(i) / 2
            let isTorn = torn > 0 && (fromRight ? x >= tip : x <= tip)
            return CGPoint(x: x, y: isTorn ? (i.isMultiple(of: 2) ? depth : 0) : untornY)
        }
    }

    func path(in rect: CGRect) -> Path {
        let count = max(1, Int(rect.width / tooth))
        let step = rect.width / CGFloat(count)
        let depth = tooth * 0.6
        let top = Self.cutLine(width: rect.width, torn: torn, fromRight: fromRight,
                               tooth: tooth, untornY: 0)
        return Path { p in
            p.addLines(top)
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - depth))
            for i in (0..<count).reversed() {
                p.addLine(to: CGPoint(x: step * (CGFloat(i) + 0.5), y: rect.maxY))
                p.addLine(to: CGPoint(x: step * CGFloat(i), y: rect.maxY - depth))
            }
            p.closeSubpath()
        }
    }
}

/// 撕下后留在出纸口里的那一截：上边贴着切刀，下边在撕开的地方是锯齿。
private struct ReceiptStub: Shape {
    var torn: CGFloat
    var fromRight: Bool
    var tooth: CGFloat = 6

    var animatableData: CGFloat {
        get { torn }
        set { torn = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let bottom = ReceiptEdge.cutLine(width: rect.width, torn: torn, fromRight: fromRight,
                                         tooth: tooth, untornY: tooth * 0.6)
        return Path { p in
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: rect.maxX, y: 0))
            p.addLines(bottom.reversed())
            p.closeSubpath()
        }
    }
}

struct ReceiptView: View {
    let theme: PanelTheme
    let clusterEnabled: Bool
    var store: UsageStore = .shared
    let onBack: () -> Void

    private enum Phase { case printing, ready, detached, flying, shared }

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
                if phase == .shared {
                    sharePage(size: geo.size)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    stage(size: geo.size)
                }
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
            if phase == .shared {
                if savedURL != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.statusHealthy)
                    Text(tr("已复制到剪贴板，并保存到「下载」", "Copied to clipboard and saved to Downloads"))
                        .foregroundStyle(theme.textSecondary)
                } else if exportFailed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.statusWarning)
                    Text(tr("小票图片保存失败", "Couldn't save the receipt image"))
                        .foregroundStyle(theme.textSecondary)
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

    // MARK: 出纸与撕拉

    private func stage(size: CGSize) -> some View {
        ReceiptTearStage(receipt: receipt, sessionsLocalOnly: clusterEnabled, state: tear,
                         attached: phase == .printing || phase == .ready,
                         showStub: phase != .printing, size: size,
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
                        flyAway(value)
                    } else {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { tear.drag = .zero }
                        NSCursor.openHand.set()
                    }
                case .detached:
                    flyAway(value)
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

    /// 按松手时的速度和方向甩出去；几乎没甩就顺着往下掉
    private func flyAway(_ value: DragGesture.Value) {
        NSCursor.arrow.set()
        guard !reduceMotion else {
            phase = .shared
            return
        }
        var dx = value.predictedEndTranslation.width - value.translation.width
        var dy = value.predictedEndTranslation.height - value.translation.height
        if hypot(dx, dy) < 80 {
            dx = tear.fromRight ? -0.3 : 0.3
            dy = 1
        }
        let length = hypot(dx, dy)
        phase = .flying
        withAnimation(.easeIn(duration: 0.38)) {
            tear.fly = CGSize(width: dx / length * 560, height: dy / length * 560)
            tear.flySpin = dx >= 0 ? 28 : -28
            tear.flyOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard phase == .flying else { return }
            withAnimation(.easeOut(duration: 0.25)) { phase = .shared }
        }
    }

    // MARK: 分享页

    private func sharePage(size: CGSize) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(tr("撕好了！", "Torn off!"))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                Text(tr("把这张 AI 对账单分享出去吧", "Share your AI receipt"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }
            if let shareImage {
                Image(nsImage: shareImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: max(120, size.height - 110))
                    .rotationEffect(.degrees(-2))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
            }
            HStack(spacing: 8) {
                shareButton
                PillButton(title: copied ? tr("已复制", "Copied") : tr("复制图片", "Copy Image"),
                           icon: copied ? "checkmark" : "doc.on.doc", theme: theme) {
                    Log.user("copy usage receipt image")
                    copied = copyToPasteboard()
                }
                if let savedURL {
                    PillButton(title: tr("在访达中显示", "Show in Finder"), icon: "folder", theme: theme) {
                        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
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
        let paper = ReceiptPaper(receipt: receipt, sessionsLocalOnly: clusterEnabled, torn: 1)
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

    /// 走纸：一顿一顿地往外吐，像热敏打印机逐行出纸
    private func startPrint() {
        printTask?.cancel()
        phase = .printing
        tear.drag = .zero
        tear.fromRight = false
        tear.fly = .zero
        tear.flySpin = 0
        tear.flyOpacity = 1
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
            let steps = 16
            for step in 1...steps {
                try? await Task.sleep(nanoseconds: 85_000_000)
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 0.06)) {
                    tear.printProgress = CGFloat(step) / CGFloat(steps)
                }
            }
            phase = .ready
            prepareImage()
        }
    }
}

/// 出纸与撕拉的全部可变状态。手势只改它，画面只读它——出纸区因此是
/// 这份状态的纯函数，测试可以直接摆出「撕到一半」来截图核对。
struct TearState: Equatable {
    var printProgress: CGFloat = 0
    var drag: CGSize = .zero
    var fromRight = false
    /// 撕断那一刻的手势位移与倾角：之后纸完全跟手，从这里接着走
    var detachDrag: CGSize = .zero
    var detachAngle: Double = 0
    var fly: CGSize = .zero
    var flySpin: Double = 0
    var flyOpacity: Double = 1
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

    var body: some View {
        let scale = min(1, max(0.5, (size.height - Self.cutterY - 8) / max(1, paperHeight)))
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
                ReceiptStub(torn: progress, fromRight: state.fromRight)
                    .fill(ReceiptPaper.paper)
                    .overlay(ReceiptStub(torn: progress, fromRight: state.fromRight)
                        .stroke(ReceiptPaper.faint.opacity(0.45), lineWidth: 0.6))
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                    .frame(width: ReceiptPaper.width, height: 7)
            }
            if let receipt {
                paper(receipt, progress: progress)
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

    private func paper(_ receipt: UsageReceipt, progress: CGFloat) -> some View {
        let angle: Double
        let anchor: UnitPoint
        var offset = CGSize.zero
        if attached {
            // 还连着：绕撕口推进到的那一点转，撕开的一侧往下掉，裂口张开
            angle = ReceiptView.tearAngle(progress: progress, fromRight: state.fromRight)
            anchor = UnitPoint(x: ReceiptView.tearTip(progress: progress, fromRight: state.fromRight)
                                   / ReceiptPaper.width, y: 0)
        } else {
            // 已撕断：从断开的那一角接着走，完全跟手
            let dx = state.drag.width - state.detachDrag.width
            angle = state.detachAngle + max(-12, min(12, Double(dx) / 25)) + state.flySpin
            anchor = UnitPoint(x: state.fromRight ? 0 : 1, y: 0)
            offset = CGSize(width: dx + state.fly.width,
                            height: state.drag.height - state.detachDrag.height + state.fly.height)
        }
        return ReceiptPaper(receipt: receipt, sessionsLocalOnly: sessionsLocalOnly,
                            torn: progress, tearFromRight: state.fromRight)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { paper in
                Color.clear.preference(key: PaperHeightKey.self, value: paper.size.height)
            })
            .shadow(color: .black.opacity(attached ? 0.16 : 0.3), radius: attached ? 5 : 12,
                    y: attached ? 3 : 8)
            .rotationEffect(.degrees(angle), anchor: anchor)
            .offset(x: offset.width, y: offset.height - (1 - state.printProgress) * paperHeight)
            .opacity(state.flyOpacity)
            .gesture(gesture)
            .onHover(perform: onHoverPaper)
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
