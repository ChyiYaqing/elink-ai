import AppKit
import SwiftUI

/// 小票纸面。颜色固定为热敏纸的米白与墨黑，不跟随面板主题——它模拟的是一张实物。
struct ReceiptPaper: View {
    let receipt: UsageReceipt
    /// 开了集群时费用与 token 是全集群的，会话数却只能数本机的 transcript
    var sessionsLocalOnly = false
    /// 撕下后顶边也是锯齿；还连在出纸口上时是直边
    var tornTop = false

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
            .padding(.top, tornTop ? 18 : 12)
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
        .clipShape(ReceiptEdge(topTeeth: tornTop))
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

/// 小票外形：底边始终是切刀留下的锯齿，顶边撕下后也变成锯齿。
struct ReceiptEdge: Shape {
    var topTeeth = false
    var tooth: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        let count = max(1, Int(rect.width / tooth))
        let step = rect.width / CGFloat(count)
        let depth = tooth * 0.6
        return Path { p in
            p.move(to: CGPoint(x: 0, y: topTeeth ? depth : 0))
            if topTeeth {
                for i in 0..<count {
                    p.addLine(to: CGPoint(x: step * (CGFloat(i) + 0.5), y: 0))
                    p.addLine(to: CGPoint(x: step * CGFloat(i + 1), y: depth))
                }
            } else {
                p.addLine(to: CGPoint(x: rect.maxX, y: 0))
            }
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - depth))
            for i in (0..<count).reversed() {
                p.addLine(to: CGPoint(x: step * (CGFloat(i) + 0.5), y: rect.maxY))
                p.addLine(to: CGPoint(x: step * CGFloat(i), y: rect.maxY - depth))
            }
            p.closeSubpath()
        }
    }
}

/// 撕到一半的裂口：从拉扯的那一侧沿切刀向另一侧推进的一道锯齿线。
private struct TearCrack: Shape {
    var progress: CGFloat
    var fromRight: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let length = rect.width * min(1, max(0, progress))
        let step: CGFloat = 6
        return Path { p in
            var x: CGFloat = 0
            var up = true
            p.move(to: CGPoint(x: fromRight ? rect.maxX : 0, y: rect.midY))
            while x < length {
                x = min(length, x + step / 2)
                let px = fromRight ? rect.maxX - x : x
                p.addLine(to: CGPoint(x: px, y: up ? rect.minY : rect.maxY))
                up.toggle()
            }
        }
    }
}

struct ReceiptView: View {
    let theme: PanelTheme
    let clusterEnabled: Bool
    var store: UsageStore = .shared
    let onBack: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var range: StatsRange = .day
    @State private var receipt: UsageReceipt?
    @State private var paperHeight: CGFloat = 520
    @State private var printProgress: CGFloat = 0
    @State private var printTask: Task<Void, Never>?
    @State private var pull: CGSize = .zero
    @State private var torn = false
    @State private var tornOffset: CGSize = .zero
    @State private var tornAngle: Double = 0
    @State private var tornDrag: CGSize = .zero
    @State private var tornReceipt: UsageReceipt?
    @State private var savedURL: URL?
    @State private var exportFailed = false

    /// 向下拉多远算撕断
    private static let tearDistance: CGFloat = 90
    private static let slotHeight: CGFloat = 14

    var body: some View {
        VStack(spacing: 10) {
            header
            GeometryReader { geo in
                stage(size: geo.size)
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
            if torn {
                if let savedURL {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.statusHealthy)
                    Text(tr("已复制到剪贴板，并保存到「下载」", "Copied to clipboard and saved to Downloads"))
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                    PillButton(title: tr("在访达中显示", "Show in Finder"), icon: "folder", theme: theme) {
                        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
                    }
                } else if exportFailed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.statusWarning)
                    Text(tr("小票图片保存失败", "Couldn't save the receipt image"))
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                } else {
                    Spacer()
                }
                PillButton(title: tr("再出一张", "Print again"), icon: "printer", theme: theme) {
                    Log.user("reprint usage receipt")
                    startPrint()
                }
            } else {
                Image(systemName: "hand.draw")
                    .foregroundStyle(theme.textTertiary)
                Text(printProgress < 1
                     ? tr("正在出票…", "Printing…")
                     : tr("按住小票向下拉，撕下后自动复制并保存为图片",
                          "Pull the receipt down to tear it off — it's copied and saved as an image"))
                    .foregroundStyle(theme.textTertiary)
                Spacer()
            }
        }
        .font(.system(size: 9, weight: .medium))
        .frame(height: 24)
    }

    private func stage(size: CGSize) -> some View {
        // 出纸口下方的可用高度装不下整张时整体缩小，保证撕之前能看到全貌
        let available = max(120, size.height - Self.slotHeight - 12)
        let scale = min(1, available / max(1, paperHeight))
        let shown = paperHeight * scale
        let tear = min(1, max(0, pull.height) / Self.tearDistance)
        return ZStack(alignment: .top) {
            if let receipt, !torn {
                ReceiptPaper(receipt: receipt, sessionsLocalOnly: clusterEnabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { paper in
                        Color.clear.preference(key: PaperHeightKey.self, value: paper.size.height)
                    })
                    .scaleEffect(scale, anchor: .top)
                    .frame(height: shown, alignment: .top)
                    .overlay(alignment: .top) {
                        // 裂口贴着切刀，随拉扯进度从拉的那一侧推进
                        TearCrack(progress: tear, fromRight: pull.width < 0)
                            .stroke(ReceiptPaper.faint, lineWidth: 1)
                            .frame(width: ReceiptPaper.width * scale, height: 4)
                            .padding(.top, 3)
                            .opacity(tear > 0 ? 1 : 0)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    // 还连在机器上：纸被拉长一点、跟着手歪一点，但不会跟手走
                    .rotationEffect(.degrees(Double(max(-6, min(6, pull.width / 20))) * Double(tear)),
                                    anchor: .top)
                    .offset(x: pull.width * 0.12,
                            y: -(1 - printProgress) * shown + max(0, pull.height) * 0.3)
                    .gesture(printProgress >= 1 ? pullGesture : nil)
                    .onHover { inside in
                        guard printProgress >= 1 else { return }
                        (inside ? NSCursor.openHand : NSCursor.arrow).set()
                    }
                    .frame(width: size.width, height: size.height - Self.slotHeight / 2, alignment: .top)
                    .clipped()
                    .padding(.top, Self.slotHeight / 2)
            }
            if let tornReceipt, torn {
                ReceiptPaper(receipt: tornReceipt, sessionsLocalOnly: clusterEnabled, tornTop: true)
                    .fixedSize(horizontal: false, vertical: true)
                    .scaleEffect(scale * 0.92, anchor: .top)
                    .frame(height: shown * 0.92, alignment: .top)
                    .shadow(color: .black.opacity(0.28), radius: 10, y: 6)
                    .rotationEffect(.degrees(tornAngle))
                    .offset(x: tornOffset.width + tornDrag.width,
                            y: tornOffset.height + tornDrag.height)
                    .gesture(
                        DragGesture()
                            .onChanged { tornDrag = $0.translation; NSCursor.closedHand.set() }
                            .onEnded { value in
                                tornOffset.width += value.translation.width
                                tornOffset.height += value.translation.height
                                tornDrag = .zero
                                NSCursor.openHand.set()
                            }
                    )
                    .onHover { ($0 ? NSCursor.openHand : NSCursor.arrow).set() }
                    .transition(.identity)
                    .zIndex(1)
            }
            slot
                .zIndex(2)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .onPreferenceChange(PaperHeightKey.self) { paperHeight = $0 }
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

    private var pullGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                pull = value.translation
                NSCursor.closedHand.set()
            }
            .onEnded { value in
                let flung = value.predictedEndTranslation.height > Self.tearDistance * 1.6
                if value.translation.height >= Self.tearDistance || flung {
                    tearOff(at: value.translation)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { pull = .zero }
                    NSCursor.openHand.set()
                }
            }
    }

    private func tearOff(at translation: CGSize) {
        guard let receipt else { return }
        Log.user("tear off usage receipt (\(range.rawValue))")
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        // 从手松开的位置接着落下，再歪着停住，像被随手扔在桌上
        tornOffset = CGSize(width: translation.width * 0.12, height: translation.height * 0.3)
        tornAngle = Double(max(-6, min(6, translation.width / 20)))
        tornReceipt = receipt
        torn = true
        pull = .zero
        savedURL = nil
        exportFailed = false
        let direction: Double = translation.width < 0 ? 1 : -1
        withAnimation(.spring(response: 0.55, dampingFraction: 0.62)) {
            tornOffset = CGSize(width: max(-30, min(30, translation.width * 0.3)), height: 24)
            tornAngle = direction * 7 + Double(max(-5, min(5, translation.width / 25)))
        }
        NSCursor.arrow.set()
        export(receipt)
    }

    private func export(_ receipt: UsageReceipt) {
        let paper = ReceiptPaper(receipt: receipt, sessionsLocalOnly: clusterEnabled, tornTop: true)
            .padding(24)
        let renderer = ImageRenderer(content: paper)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else {
            exportFailed = true
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        pasteboard.setData(png, forType: .png)
        pasteboard.setData(tiff, forType: .tiff)
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
        torn = false
        tornReceipt = nil
        tornDrag = .zero
        pull = .zero
        printProgress = 0
        guard !reduceMotion else {
            printProgress = 1
            return
        }
        printTask = Task { @MainActor in
            let steps = 16
            for step in 1...steps {
                try? await Task.sleep(nanoseconds: 85_000_000)
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 0.06)) {
                    printProgress = CGFloat(step) / CGFloat(steps)
                }
            }
        }
    }
}

private struct PaperHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
