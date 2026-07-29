import SwiftUI

/// 单个节点的往返延迟随时间的波动。
///
/// 折线是每个五分钟桶的平均值，线后面那条淡色带是同一个桶的 min–max。只画平均会把
/// 尖峰抹平——探测 30 秒一次，一个桶里有十个样本，实测见过 763µs–5339µs 的桶，七倍
/// 抖动在平均值上完全看不出来，而抖动正是「波动情况」本身。
///
/// 一次都没通的桶**断线**，不连过去。跨着一段断网把两端连起来，等于画出一条那段时间
/// 根本不存在的延迟曲线——这是这类图最有害的错误，比画成 0ms 更隐蔽。断口另用警示色
/// 在基线上标点，让「没有数据」和「数据很好」在视觉上无法混淆。
struct MeshLatencyChart: View {
    let points: [MeshBucketPoint]
    let theme: PanelTheme
    /// 悬停到某个桶时回调，交给外层把数字显示在标题栏——比在 34pt 高的图里挤 tooltip 可读。
    var onHover: ((MeshBucketPoint?) -> Void)?

    @State private var hoveredIndex: Int?

    /// 延迟是数据序列，不是状态，因此不复用 statusHealthy 那套绿/黄/红；用面板本身的
    /// 紫作为单序列色，与状态色天然分开。两种模式的取值都过了亮度带、色度、色觉障碍
    /// 分离度与对比度校验。
    private var seriesColor: Color {
        theme.dark ? Color(red: 0.60, green: 0.49, blue: 0.91)
                   : Color(red: 0.48, green: 0.32, blue: 0.85)
    }

    private var lossColor: Color {
        theme.dark ? Color(red: 0.91, green: 0.37, blue: 0.47)
                   : Color(red: 0.92, green: 0.35, blue: 0.44)
    }

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
        guard high > low else {
            // 全窗口一个值：给它一成的余量，否则线会贴在边框上
            let padding = max(Double(high) * 0.1, 1)
            return (Double(low) - padding, Double(high) + padding)
        }
        // 上下各留一成，线和带不会贴着上下边缘被裁掉
        let padding = Double(high - low) * 0.1
        return (Double(low) - padding, Double(high) + padding)
    }

    /// 窗口内一次都没通：没有任何曲线可画，留一个空图框只会让人以为渲染坏了。
    /// 缩成一条断口带，让「全断」看起来就是全断。
    var hasPlottableData: Bool { points.contains { $0.rttAvgUs != nil } }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                // 全断时没有线也没有带，红点会悬在空处像是装饰。一条基线把它们

                // 锚成一条时间轴，「什么时候断的、断了多久」才读得出来。
                if !hasPlottableData {
                    Rectangle()
                        .fill(theme.textTertiary.opacity(0.35))
                        .frame(height: 1)
                        .position(x: size.width / 2, y: size.height - 1.5)
                }
                band(in: size)
                    .fill(seriesColor.opacity(theme.dark ? 0.22 : 0.16))
                ForEach(Array(segments().enumerated()), id: \.offset) { segment in
                    line(segment.element, in: size)
                        .stroke(seriesColor,
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                lossMarkers(in: size)
                crosshair(in: size)
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

    // MARK: - 几何

    private func x(_ index: Int, width: CGFloat) -> CGFloat {
        guard points.count > 1 else { return width / 2 }
        return width * CGFloat(index) / CGFloat(points.count - 1)
    }

    private func y(_ micros: Int, height: CGFloat) -> CGFloat {
        let (lower, upper) = bounds
        let span = max(upper - lower, 1)
        return height - CGFloat((Double(micros) - lower) / span) * height
    }

    private func nearestIndex(to positionX: CGFloat, width: CGFloat) -> Int? {
        guard !points.isEmpty else { return nil }
        guard points.count > 1 else { return 0 }
        let ratio = max(0, min(1, positionX / width))
        return Int((ratio * CGFloat(points.count - 1)).rounded())
    }

    /// 连续可用桶的下标分段。断口把折线切开，而不是让它跨过去。
    static func segments(_ points: [MeshBucketPoint]) -> [[Int]] {
        var result: [[Int]] = []
        var current: [Int] = []
        for (index, point) in points.enumerated() {
            if point.rttAvgUs != nil {
                current.append(index)
            } else if !current.isEmpty {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func segments() -> [[Int]] { Self.segments(points) }

    private func line(_ indices: [Int], in size: CGSize) -> Path {
        Path { path in
            // 孤立的一个点画不出线段，补一个短横杠，否则它会整个消失
            if indices.count == 1, let value = points[indices[0]].rttAvgUs {
                let center = CGPoint(x: x(indices[0], width: size.width),
                                     y: y(value, height: size.height))
                path.move(to: CGPoint(x: center.x - 1, y: center.y))
                path.addLine(to: CGPoint(x: center.x + 1, y: center.y))
                return
            }
            for (offset, index) in indices.enumerated() {
                guard let value = points[index].rttAvgUs else { continue }
                let position = CGPoint(x: x(index, width: size.width),
                                       y: y(value, height: size.height))
                if offset == 0 { path.move(to: position) } else { path.addLine(to: position) }
            }
        }
    }

    /// min–max 区间带，同样按可用段切开。
    private func band(in size: CGSize) -> Path {
        Path { path in
            for indices in segments() {
                guard indices.count > 1 else { continue }
                var closing: [CGPoint] = []
                for (offset, index) in indices.enumerated() {
                    guard let high = points[index].rttMaxUs,
                          let low = points[index].rttMinUs else { continue }
                    let positionX = x(index, width: size.width)
                    let top = CGPoint(x: positionX, y: y(high, height: size.height))
                    if offset == 0 { path.move(to: top) } else { path.addLine(to: top) }
                    closing.append(CGPoint(x: positionX, y: y(low, height: size.height)))
                }
                for position in closing.reversed() { path.addLine(to: position) }
                path.closeSubpath()
            }
        }
    }

    private func lossMarkers(in size: CGSize) -> some View {
        ForEach(points.indices.filter { points[$0].fullyLost }, id: \.self) { index in
            Circle()
                .fill(lossColor)
                .frame(width: 3, height: 3)
                .position(x: x(index, width: size.width), y: size.height - 1.5)
        }
    }

    @ViewBuilder
    private func crosshair(in size: CGSize) -> some View {
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
                    .position(x: positionX, y: y(value, height: size.height))
            }
        }
    }
}
