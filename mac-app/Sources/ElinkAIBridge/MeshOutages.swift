import Foundation

/// 一段连续的完全不通。
///
/// 「探了一个都没回来」和「丢了一两个包」必须分开。实测这张网上跨境链路每五分钟丢
/// 一两个探测是常态——十台里有四台一直在丢——而连续整桶全丢才是中断。两者同色同权重
/// 画出来，页面上就满眼告警，真事故反而藏在里面。
struct MeshOutage: Equatable {
    /// 第一个全丢桶的起点。
    var start: Date
    /// 最后一个全丢桶的终点。
    var end: Date
    /// 跨了几个桶。
    var buckets: Int
    /// 窗口里最后一个桶仍然全丢：还没恢复。没恢复是现在的事故，已恢复是历史，
    /// 说法不能一样。
    var ongoing: Bool

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// 一台节点在这个窗口里的严重程度。顺序即排序依据：坏的排前面。
enum MeshFault: Int, Comparable {
    /// 窗口内没丢过。
    case clean = 0
    /// 有丢包，但没有整桶全丢。
    case loss = 1
    /// 窗口内断过，现在通了。
    case recovered = 2
    /// 现在就不通。
    case down = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 一台节点的结论，页面用它排序和写摘要。
struct MeshHostReport: Equatable {
    var name: String
    var fault: MeshFault
    /// 写「什么时候」用的那些中断。
    var outages: [MeshOutage]
}

enum MeshAnalysis {
    /// 连续全丢的区间。
    ///
    /// 桶之间缺了一个就断开成两段：中间那段是「没探测」，把它算进中断等于替一段
    /// 本机在睡觉的时间作证。
    static func outages(in points: [MeshBucketPoint],
                        bucketWidth: TimeInterval = UsageStore.meshBucketWidth) -> [MeshOutage] {
        let ordered = points.sorted { $0.bucketAt < $1.bucketAt }
        var result: [MeshOutage] = []
        var lastDownAt: Date?
        for point in ordered where point.samples > 0 && point.okSamples == 0 {
            if var last = result.last,
               point.bucketAt.timeIntervalSince(last.end) <= bucketWidth * 0.5 {
                last.end = point.bucketAt.addingTimeInterval(bucketWidth)
                last.buckets += 1
                result[result.count - 1] = last
            } else {
                result.append(MeshOutage(start: point.bucketAt,
                                         end: point.bucketAt.addingTimeInterval(bucketWidth),
                                         buckets: 1, ongoing: false))
            }
            lastDownAt = point.bucketAt
        }
        // 最后一个桶就是全丢的那个 → 还在断
        if let lastDownAt, let latest = ordered.last?.bucketAt, lastDownAt == latest,
           var last = result.last {
            last.ongoing = true
            result[result.count - 1] = last
        }
        return result
    }

    /// 现在不通 > 断过又好了 > 只是丢包 > 干净。
    ///
    /// lighthouse 视角优先用来说「什么时候」：本机视角只测得到「我到它」的隧道，网格上
    /// 大多数链路本机根本不在其上，而本机睡着的时段在它那里只是一段空白。
    static func report(name: String, state: MeshState,
                       local: [MeshBucketPoint],
                       lighthouse: [MeshBucketPoint]) -> MeshHostReport {
        let localOutages = outages(in: local)
        let lighthouseOutages = outages(in: lighthouse)
        let chosen = lighthouseOutages.isEmpty ? localOutages : lighthouseOutages
        let lost = local.reduce(0) { $0 + $1.lostSamples }
            + lighthouse.reduce(0) { $0 + $1.lostSamples }
        let fault: MeshFault
        if state != .online {
            fault = .down
        } else if !chosen.isEmpty {
            fault = .recovered
        } else {
            fault = lost > 0 ? .loss : .clean
        }
        return MeshHostReport(name: name, fault: fault, outages: chosen)
    }

    /// 坏的排前面。
    ///
    /// 同级还要再分：同是「断过」，一直没恢复的比已经好了的紧急，断了一小时的比断了
    /// 五分钟的紧急。只按名字排会让 iMac（整窗口不通）落到 WSL（断过 25 分钟已恢复）
    /// 后面——只因为字典序。最后用名字兜底，保证顺序稳定：排序每 30 秒重算一次，
    /// 名次不能自己跳。
    static func sorted(_ reports: [MeshHostReport]) -> [MeshHostReport] {
        reports.sorted { left, right in
            guard left.fault == right.fault else { return left.fault > right.fault }
            let leftOngoing = left.outages.contains(where: \.ongoing)
            let rightOngoing = right.outages.contains(where: \.ongoing)
            guard leftOngoing == rightOngoing else { return leftOngoing }
            let leftDown = left.outages.reduce(0) { $0 + $1.duration }
            let rightDown = right.outages.reduce(0) { $0 + $1.duration }
            guard leftDown == rightDown else { return leftDown > rightDown }
            return left.name < right.name
        }
    }

    /// 一台节点的中断说成一句话。取最长的那一段：一个窗口里断三次，先要知道最狠的那次。
    static func outageText(_ outages: [MeshOutage], window: ClosedRange<Date>,
                           bucketWidth: TimeInterval = UsageStore.meshBucketWidth,
                           locale: Locale = .current) -> String? {
        guard let worst = outages.max(by: { $0.duration < $1.duration }) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        let from = formatter.string(from: worst.start)
        guard worst.ongoing else {
            return tr("\(from)–\(formatter.string(from: worst.end)) 不通",
                      "down \(from)–\(formatter.string(from: worst.end))")
        }
        // 从窗口开头就断到现在，说「18:10 起」会让人以为 18:10 之前是好的
        guard worst.start > window.lowerBound.addingTimeInterval(bucketWidth) else {
            return tr("整个窗口都不通", "down for the whole window")
        }
        return tr("\(from) 起不通", "down since \(from)")
    }

    /// 页面顶上那一句：有没有问题、哪几台、什么时候。这一句要能在不滚动、不悬停的
    /// 情况下把「连接什么时候有问题」答完。
    static func headline(_ reports: [MeshHostReport], window: ClosedRange<Date>,
                        bucketWidth: TimeInterval = UsageStore.meshBucketWidth,
                        locale: Locale = .current) -> String {
        let problems = sorted(reports).filter { $0.fault >= .recovered }
        guard !problems.isEmpty else {
            guard reports.contains(where: { $0.fault == .loss }) else {
                return tr("窗口内没有中断", "No outage in this window")
            }
            return tr("窗口内没有中断，只有零星丢包",
                      "No outage in this window, only scattered loss")
        }
        let parts = problems.prefix(2).map { report -> String in
            let when = outageText(report.outages, window: window,
                                  bucketWidth: bucketWidth, locale: locale)
            return "\(report.name) \(when ?? tr("不通", "down"))"
        }
        let rest = problems.count - parts.count
        let tail = rest > 0 ? tr(" · 另有 \(rest) 台", " · \(rest) more") : ""
        return parts.joined(separator: " · ") + tail
    }
}
