import SwiftUI

/// 一个五分钟桶的可达性结论。顺序即严重程度，色带按它决定谁盖住谁。
enum MeshBucketStatus: Int, Comparable {
    /// 这五分钟根本没探测过——本机休眠、应用没跑，或者 lighthouse 那时不在。
    /// 不是「好」，也不是「坏」，是「没在看」。
    case noData = 0
    case ok = 1
    /// 探通了一部分。丢包本身就是故障的前兆，不该和全通同色。
    case partial = 2
    /// 探了，一个都没回来。
    case lost = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    static func of(_ point: MeshBucketPoint) -> Self {
        if point.samples <= 0 { return .noData }
        if point.okSamples == 0 { return .lost }
        return point.lostSamples > 0 ? .partial : .ok
    }
}

/// 一条按时间铺开的可达性色带：每个五分钟桶一格，四种状态四种颜色。
///
/// 延迟折线回答的是「快不快」，这条带回答的是「通不通」，而事故要看的是后者。折线上
/// 一次夜间中断只是几个 3pt 的红点，混在一段本来就没有数据的空白里；色带把同一段时间
/// 铺满整条宽度，断在哪、断了多久，一眼就是一段红。
///
/// 两条规则不能省：
///
/// 一是**坏的盖住好的**。一天的窗口下一个桶只有一个多像素，若按数据顺序绘制，后面一个
/// 正常桶会把前面那次中断整个覆盖掉——一张说「一切正常」的图，恰恰是在最需要它说实话
/// 的时候撒谎。因此按严重程度升序绘制，越坏越后画。
///
/// 二是**最小可见宽度**。5 分钟占一天的 0.35%，在面板那 390pt 宽的图上是 1.4pt，不设
/// 下限就等于没画。给每格至少 2pt，让一次短暂中断在最宽的窗口下依然是一根看得见的红线。
struct MeshAvailabilityStrip: View {
    let points: [MeshBucketPoint]
    let window: ClosedRange<Date>
    let theme: PanelTheme

    /// 单格最小宽度，见上文。
    static let minimumMarkWidth: CGFloat = 2

    /// 每格的绘制矩形，按严重程度升序——调用顺序即图层顺序。
    /// 抽成纯函数是为了能直接断言「坏的在后面画」和「窄格被撑到可见」。
    static func marks(points: [MeshBucketPoint], window: ClosedRange<Date>,
                      width: CGFloat) -> [(status: MeshBucketStatus, x: CGFloat, width: CGFloat)] {
        points
            .map { point -> (MeshBucketStatus, CGFloat, CGFloat) in
                let start = MeshLatencyChart.position(point.bucketAt, in: window, width: width)
                let end = MeshLatencyChart.position(
                    point.bucketAt.addingTimeInterval(UsageStore.meshBucketWidth),
                    in: window, width: width
                )
                let markWidth = max(end - start, minimumMarkWidth)
                // 撑宽后不许越出右边缘，否则最后一格会被裁成半格
                let markX = min(start, max(0, width - markWidth))
                return (MeshBucketStatus.of(point), markX, markWidth)
            }
            .sorted { $0.0 < $1.0 }
            .map { (status: $0.0, x: $0.1, width: $0.2) }
    }

    func color(_ status: MeshBucketStatus) -> Color {
        switch status {
        case .noData: return theme.textTertiary.opacity(theme.dark ? 0.20 : 0.16)
        case .ok: return theme.statusHealthy.opacity(theme.dark ? 0.75 : 0.65)
        case .partial: return theme.statusWarning
        case .lost: return theme.dark ? Color(red: 0.91, green: 0.37, blue: 0.47)
                                      : Color(red: 0.92, green: 0.35, blue: 0.44)
        }
    }

    var body: some View {
        Canvas { context, size in
            // 整条先铺成「没在看」，有桶的时段再覆盖上去。没有这层底色，缺数据的时段
            // 会和背景一样，读起来像是「这段时间没出问题」。
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color(.noData)))
            for mark in Self.marks(points: points, window: window, width: size.width) {
                context.fill(
                    Path(CGRect(x: mark.x, y: 0, width: mark.width, height: size.height)),
                    with: .color(color(mark.status))
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}
