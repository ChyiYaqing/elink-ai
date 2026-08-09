import SwiftUI

/// 单个节点的往返延迟随时间的波动。
///
/// 折线是每个五分钟桶的平均值，线后面每格一根竖条，画的是同一个桶的 min–max。只画
/// 平均会把尖峰抹平——探测 30 秒一次，一个桶里有十个样本，实测见过 763µs–5339µs 的
/// 桶，七倍抖动在平均值上完全看不出来，而抖动正是「波动情况」本身。
///
/// 纵轴是对数刻度，见 `logValue`：延迟重尾，线性轴下一个 481ms 的尖峰就能把日常的
/// 10–35ms 压成贴着底边的一条平线。
///
/// 横轴是时间，不是样本下标。这一条是被一次真实事故换来的：早期版本按 `index /
/// (count - 1)` 定位，而查询只返回**库里存在**的桶，于是本机休眠的那几个小时直接从
/// 轴上消失，凌晨两点和早上八点被画成相邻两点、连成一条连续的线。夜里断没断，在那种
/// 轴上永远看不出来。按时间定位后，没有数据的时段就是横轴上一段空白。
///
/// 一次都没通的桶**断线**，不连过去。跨着一段断网把两端连起来，等于画出一条那段时间
/// 根本不存在的延迟曲线——这是这类图最有害的错误，比画成 0ms 更隐蔽。
///
/// 基线上另有一行丢包标记：高度随丢包比例走，全丢的用中断色。它和上方的竖条分属两个
/// 通道——竖条说「多慢」，基线说「丢了多少」。一个桶丢掉三成探测，剩下七成照样算得出
/// 正常的 min/max，竖条因此和健康的格子一模一样；不单独画出来，丢包在这张图上就是隐形的。
///
/// 「探了但全丢」和「根本没探」是两件不同的事，前者是故障、后者只是没在看，因此前者
/// 在基线上有一个满高的中断标记，后者是横轴上一段什么都没有的空白。这两者绝不能长得像。
struct MeshLatencyChart: View {
    let points: [MeshBucketPoint]
    /// 横轴的时间范围。由调用方给定而不是从数据推导：两张图（本机视角与 lighthouse
    /// 视角）必须共用同一根时间轴，否则上下对照读出来的是错的。
    let window: ClosedRange<Date>
    let theme: PanelTheme
    /// 悬停到某个桶时回调，交给外层把数字显示在标题栏——比在图里挤 tooltip 可读。
    var onHover: ((MeshBucketPoint?) -> Void)?
    /// 折叠列表里这张图只有二十几点高，两个 8pt 的刻度标签会把它整个盖住。
    /// 那里要回答的也不是「多少毫秒」，而是「有没有在抖、有没有丢包」。
    var showsScale = true

    @State private var hoveredIndex: Int?

    /// 延迟是数据序列，不是状态，因此不复用 statusHealthy 那套绿/黄/红；单序列色由
    /// 主题给出，各套主题都保证它与三个状态色分得开。
    private var seriesColor: Color { theme.seriesColor }

    private var lossColor: Color { theme.statusCritical }

    /// 纵轴取这台节点自己的数据范围，不从零起。
    ///
    /// 零基线是柱状图的规则——柱长直接编码量值，截断就是撒谎。折线不同：它编码的是
    /// 变化，而延迟永远不会接近零。实测过一次零基线版本，Bandwagon2 的 199–221ms
    /// 被压进 0–221ms 的顶部一成，波动整个消失，下面九成是空白。
    ///
    /// 范围本身写在图上方的摘要行里（`199ms–221ms · 43 次探测`），所以截断是明示的，
    /// 不是靠读者自己发现。
    var axisBounds: (lower: Double, upper: Double) { bounds }

    private var bounds: (lower: Double, upper: Double) {
        let lows = points.compactMap(\.rttMinUs)
        let highs = points.compactMap(\.rttMaxUs)
        guard let low = lows.min(), let high = highs.max() else { return (0, 1) }
        // 余量在对数空间里给，和 y() 的映射保持同一套刻度；否则窄范围的序列
        // （199–221ms）留出的余量在图上会看不见，宽范围的又会留得过多。
        guard high > low else {
            // 全窗口一个值：上下各给一成，否则线会贴在边框上
            return (Double(low) / 1.1, Double(high) * 1.1)
        }
        let span = Self.logValue(Double(high)) - Self.logValue(Double(low))
        return (pow(10, Self.logValue(Double(low)) - span * 0.1),
                pow(10, Self.logValue(Double(high)) + span * 0.1))
    }

    /// 纵轴取对数刻度。
    ///
    /// 延迟是重尾的：这条链路实测 8.88ms–481ms，日常在 10–35ms，481ms 是单次探测的
    /// 尖峰。线性轴下上界被那一个尖峰绑架，日常波动被压进底部 5% 的高度里，均值线成了
    /// 一条贴着底边的平线——而「波动」正是这张图要回答的问题。同一份数据换成对数刻度，
    /// 那段波动占到图高的三分之一。
    ///
    /// 对数不丢数据，这一点和「砍掉尖峰」的做法不同：尖峰仍然画在图上，只是不再独占
    /// 整根轴。代价是形状不能当量值读，所以刻度标签旁标了 `log`，两端的真实值也仍然
    /// 写在轴上和摘要行里。
    static func logValue(_ micros: Double) -> Double { log10(max(micros, 1)) }

    /// 窗口内一次都没通：没有任何曲线可画，留一个空图框只会让人以为渲染坏了。
    /// 缩成一条断口带，让「全断」看起来就是全断。
    var hasPlottableData: Bool { points.contains { $0.rttAvgUs != nil } }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            // 纵轴范围一次算好往下传。它要扫一遍所有桶，而每个点的 y 都要用它：以前在
            // y() 里现算，一张 288 个桶的图就成了 O(n²)，面板里 8 台 × 2 条 = 16 张图
            // 一起重画时，单次布局要占掉半秒主线程。
            let scale = bounds
            ZStack(alignment: .topLeading) {
                // 全断时没有线也没有竖条，丢包标记会悬在空处像是装饰。一条基线把它们
                // 锚成一条时间轴，「什么时候断的、断了多久」才读得出来。
                if !hasPlottableData {
                    Rectangle()
                        .fill(theme.textTertiary.opacity(0.35))
                        .frame(height: 1)
                        .position(x: size.width / 2, y: size.height - 1.5)
                }
                spread(in: size, scale: scale)
                    .fill(seriesColor.opacity(theme.dark ? 0.38 : 0.28))
                ForEach(Array(segments().enumerated()), id: \.offset) { segment in
                    line(segment.element, in: size, scale: scale)
                        .stroke(seriesColor,
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                lossMarks(in: size).fill(theme.statusWarning)
                outageMarks(in: size).fill(lossColor)
                crosshair(in: size, scale: scale)
                if showsScale { scaleLabels }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let index = nearestIndex(to: location.x, width: size.width)
                    if index != hoveredIndex {
                        hoveredIndex = index
                        onHover?(index.map { points[$0] })
                    }
                case .ended:
                    hoveredIndex = nil
                    onHover?(nil)
                }
            }
        }
    }

    /// 纵轴的上下界写在图里。
    ///
    /// 纵轴不从零起（见 `bounds`），所以两张叠在一起的图形状可以很像而量级差二十倍：
    /// 本机到 3B 是 15–19ms，lighthouse 到 3B 是 210–467ms，两条线都铺满整个高度。
    /// 不标出范围，读者会拿形状当量值比。
    @ViewBuilder
    private var scaleLabels: some View {
        if let low = points.compactMap(\.rttMinUs).min(),
           let high = points.compactMap(\.rttMaxUs).max() {
            VStack(alignment: .leading, spacing: 0) {
                // 刻度是对数的，形状不能当量值读——标出来，别让人自己发现
                label("\(UsagePanelView.meshLatency(high)) · log")
                Spacer(minLength: 0)
                if high != low { label(UsagePanelView.meshLatency(low)) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(theme.textTertiary)
            .padding(.horizontal, 2)
            // 折线会穿过左上角，垫一层表面色，数字才读得出来
            .background(theme.glassBackground.opacity(0.75),
                        in: RoundedRectangle(cornerRadius: 2))
    }

    // MARK: - 几何

    /// 时间 → 横坐标。窗口零宽时退化到中点，避免除零。
    static func position(_ time: Date, in window: ClosedRange<Date>, width: CGFloat) -> CGFloat {
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        guard span > 0 else { return width / 2 }
        let ratio = time.timeIntervalSince(window.lowerBound) / span
        return width * CGFloat(max(0, min(1, ratio)))
    }

    private func x(_ index: Int, width: CGFloat) -> CGFloat {
        Self.position(points[index].bucketAt, in: window, width: width)
    }

    /// 一个延迟值在纵轴上的位置，0 是轴底、1 是轴顶。
    /// 单独拆出来是为了能直接断言「这段波动占了图高的多少」。
    func plotRatio(_ micros: Int) -> Double {
        let lower = Self.logValue(bounds.lower)
        let span = max(Self.logValue(bounds.upper) - lower, .leastNormalMagnitude)
        return max(0, min(1, (Self.logValue(Double(micros)) - lower) / span))
    }

    private func y(_ micros: Int, height: CGFloat,
                   scale: (lower: Double, upper: Double)) -> CGFloat {
        let lower = Self.logValue(scale.lower)
        let span = max(Self.logValue(scale.upper) - lower, .leastNormalMagnitude)
        let ratio = (Self.logValue(Double(micros)) - lower) / span
        return height - CGFloat(max(0, min(1, ratio))) * height
    }

    /// 悬停取横轴上最近的桶，但不跨过空白时段：鼠标停在一段没有数据的区间里时，把
    /// 几小时外的某个桶报成「当前」，读出来的就是一个假的时间点。
    private func nearestIndex(to positionX: CGFloat, width: CGFloat) -> Int? {
        guard !points.isEmpty else { return nil }
        var best: (index: Int, distance: CGFloat)?
        for index in points.indices {
            let distance = abs(x(index, width: width) - positionX)
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        guard let best else { return nil }
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        guard span > 0 else { return best.index }
        // 一个桶宽的容差：够宽到相邻桶密集时不出现死区，也够窄到不跨越空白。
        let tolerance = width * CGFloat(UsageStore.meshBucketWidth / span)
        return best.distance <= max(tolerance, 3) ? best.index : nil
    }

    /// 连续可用桶的下标分段。断口把折线切开，而不是让它跨过去。
    ///
    /// 两种断口都要切：桶存在但一次没通（`rttAvgUs == nil`），以及桶根本不存在——后者
    /// 表现为相邻两点的时间差超过一个桶宽。只切前者会让休眠时段被一条直线连过去。
    static func segments(_ points: [MeshBucketPoint]) -> [[Int]] {
        var result: [[Int]] = []
        var current: [Int] = []
        for (index, point) in points.enumerated() {
            let contiguous = current.last.map { previous in
                point.bucketAt.timeIntervalSince(points[previous].bucketAt)
                    <= UsageStore.meshBucketWidth * 1.5
            } ?? true
            if point.rttAvgUs != nil, contiguous {
                current.append(index)
                continue
            }
            if !current.isEmpty {
                result.append(current)
                current = []
            }
            if point.rttAvgUs != nil { current.append(index) }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func segments() -> [[Int]] { Self.segments(points) }

    private func line(_ indices: [Int], in size: CGSize,
                      scale: (lower: Double, upper: Double)) -> Path {
        Path { path in
            // 孤立的一个点画不出线段，补一个短横杠，否则它会整个消失
            if indices.count == 1, let value = points[indices[0]].rttAvgUs {
                let center = CGPoint(x: x(indices[0], width: size.width),
                                     y: y(value, height: size.height, scale: scale))
                path.move(to: CGPoint(x: center.x - 1, y: center.y))
                path.addLine(to: CGPoint(x: center.x + 1, y: center.y))
                return
            }
            for (offset, index) in indices.enumerated() {
                guard let value = points[index].rttAvgUs else { continue }
                let position = CGPoint(x: x(index, width: size.width),
                                       y: y(value, height: size.height, scale: scale))
                if offset == 0 { path.move(to: position) } else { path.addLine(to: position) }
            }
        }
    }

    /// 每个桶的 min–max 各画一根竖条。
    ///
    /// 早先这里是一条把相邻桶连起来的填充带。那条带把「桶与桶之间」画成了连续变化，
    /// 而每个桶是十个样本各自的聚合，桶之间没有插值可言——一个 481ms 的尖峰因此被
    /// 摊成一座横跨三个桶的平滑山峰，看起来像一段持续变慢，实际只是某一个五分钟里
    /// 抖了一下。
    ///
    /// 竖条还原了「这一格里最快到最慢之间隔多远」，抖动是逐格读的，尖峰也只占它
    /// 自己那一格。桶密到贴在一起时（24 小时窗口有 288 格）它退化成一条密纹带，
    /// 那时读到的仍然是包络，不会更糟。
    private func spread(in size: CGSize, scale: (lower: Double, upper: Double)) -> Path {
        let width = barWidth(size.width)
        return Path { path in
            for point in points {
                guard let high = point.rttMaxUs, let low = point.rttMinUs else { continue }
                let center = Self.position(point.bucketAt, in: window, width: size.width)
                let top = y(high, height: size.height, scale: scale)
                let bottom = y(low, height: size.height, scale: scale)
                // 一个桶里十个样本完全一致时高度会是零，给它至少一根线的厚度，
                // 否则「这一格探过、很稳」和「这一格没探」在图上一样是空白
                let rect = CGRect(x: center - width / 2, y: top,
                                  width: width, height: max(bottom - top, width))
                path.addRoundedRect(in: rect,
                                    cornerSize: CGSize(width: width / 2, height: width / 2))
            }
        }
    }

    /// 竖条宽度跟着桶在轴上的间距走，两端夹住：太细看不见，太粗会糊成一片。
    private func barWidth(_ width: CGFloat) -> CGFloat {
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        guard span > 0 else { return 3 }
        let spacing = width * CGFloat(UsageStore.meshBucketWidth / span)
        return max(1.5, min(7, spacing * 0.62))
    }

    /// 丢包在图上占的高度，贴着基线量。
    ///
    /// 竖条的高度编码的是延迟，不能再拿去背丢包——那会让「这一格慢」和「这一格丢包」
    /// 在同一个通道上打架。丢包因此压在基线上单独一行，和延迟互不干扰。
    ///
    /// 高度随丢包比例走，不是一律画满。实测这张网上四台节点每五分钟都会丢一两个探测，
    /// 一律画满会让这四台看着和真的断掉一样严重——那正是要区分的两件事。全丢的格子
    /// 高度最大、另用中断色，一眼压过零星丢包。
    static func lossMarkHeight(_ point: MeshBucketPoint) -> CGFloat {
        guard point.samples > 0, point.lostSamples > 0 else { return 0 }
        let fraction = CGFloat(point.lostSamples) / CGFloat(point.samples)
        // 起步 2pt：丢一个探测也要看得见，否则「丢过」和「没丢过」在图上没有区别
        return 2 + fraction * 6
    }

    private func lossMarks(in size: CGSize) -> Path {
        let width = barWidth(size.width)
        return Path { path in
            for point in points {
                let height = min(Self.lossMarkHeight(point), size.height)
                guard height > 0 else { continue }
                let center = Self.position(point.bucketAt, in: window, width: size.width)
                path.addRoundedRect(
                    in: CGRect(x: center - width / 2, y: size.height - height,
                               width: width, height: height),
                    cornerSize: CGSize(width: min(width, height) / 2,
                                       height: min(width, height) / 2))
            }
        }
    }

    /// 全丢的格子单独一层，用中断色盖在零星丢包之上
    private func outageMarks(in size: CGSize) -> Path {
        let width = barWidth(size.width)
        return Path { path in
            for point in points where point.fullyLost {
                let height = min(Self.lossMarkHeight(point), size.height)
                let center = Self.position(point.bucketAt, in: window, width: size.width)
                path.addRoundedRect(
                    in: CGRect(x: center - width / 2, y: size.height - height,
                               width: width, height: height),
                    cornerSize: CGSize(width: min(width, height) / 2,
                                       height: min(width, height) / 2))
            }
        }
    }

    @ViewBuilder
    private func crosshair(in size: CGSize,
                           scale: (lower: Double, upper: Double)) -> some View {
        if let hoveredIndex, points.indices.contains(hoveredIndex) {
            let positionX = x(hoveredIndex, width: size.width)
            Rectangle()
                .fill(theme.textTertiary.opacity(0.55))
                .frame(width: 1, height: size.height)
                .position(x: positionX, y: size.height / 2)
            if let value = points[hoveredIndex].rttAvgUs {
                Circle()
                    .fill(seriesColor)
                    // 2pt 的表面色描边把点从线和带里分出来
                    .overlay(Circle().stroke(theme.glassBackground, lineWidth: 2))
                    .frame(width: 6, height: 6)
                    .position(x: positionX, y: y(value, height: size.height, scale: scale))
            }
        }
    }
}
