import SwiftUI

enum StatsRange: String, CaseIterable {
    case week, month, year

    var title: String {
        switch self {
        case .week: return "周"
        case .month: return "月"
        case .year: return "年"
        }
    }

    var summaryTitle: String {
        switch self {
        case .week: return "近 7 天"
        case .month: return "近 30 天"
        case .year: return "近 12 个月"
        }
    }
}

struct StatsBucket: Identifiable, Equatable {
    let id: String       // 日桶 "yyyy-MM-dd"，月桶 "yyyy-MM"
    let label: String
    let models: [String: Int]
    var total: Int { models.values.reduce(0, +) }
}

enum UsageStats {
    static func buckets(rows: [DailyModelUsage], range: StatsRange, now: Date = Date()) -> [StatsBucket] {
        let calendar = StatusService.aggregationCalendar
        var byDay: [String: [String: Int]] = [:]
        for row in rows {
            byDay[row.day, default: [:]][row.model, default: 0] += row.tokens
        }
        switch range {
        case .week, .month:
            let count = range == .week ? 7 : 30
            return (0..<count).reversed().map { offset in
                let date = calendar.date(byAdding: .day, value: -offset, to: now) ?? now
                let key = StatusService.dayKey(date)
                let label = "\(calendar.component(.month, from: date))/\(calendar.component(.day, from: date))"
                return StatsBucket(id: key, label: label, models: byDay[key] ?? [:])
            }
        case .year:
            var byMonth: [String: [String: Int]] = [:]
            for (day, models) in byDay {
                let key = String(day.prefix(7))
                for (model, tokens) in models {
                    byMonth[key, default: [:]][model, default: 0] += tokens
                }
            }
            return (0..<12).reversed().map { offset in
                let date = calendar.date(byAdding: .month, value: -offset, to: now) ?? now
                let key = String(StatusService.dayKey(date).prefix(7))
                let label = "\(calendar.component(.month, from: date))月"
                return StatsBucket(id: key, label: label, models: byMonth[key] ?? [:])
            }
        }
    }

    /// 全范围内按总量降序的模型列表，决定堆叠顺序与配色
    static func modelOrder(_ buckets: [StatsBucket]) -> [String] {
        var totals: [String: Int] = [:]
        for bucket in buckets {
            for (model, tokens) in bucket.models { totals[model, default: 0] += tokens }
        }
        return totals
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map(\.key)
    }

    static let palette: [Color] = [
        Color(red: 0.98, green: 0.55, blue: 0.45), // 珊瑚
        Color(red: 0.30, green: 0.76, blue: 0.71), // 青绿
        Color(red: 0.58, green: 0.46, blue: 0.96), // 紫
        Color(red: 0.36, green: 0.62, blue: 0.98), // 蓝
        Color(red: 0.95, green: 0.68, blue: 0.28), // 琥珀
        Color(red: 0.90, green: 0.42, blue: 0.68), // 粉
        Color(red: 0.45, green: 0.80, blue: 0.38), // 绿
        Color(red: 0.62, green: 0.60, blue: 0.68), // 灰
    ]

    static func colors(for order: [String]) -> [String: Color] {
        Dictionary(uniqueKeysWithValues: order.enumerated().map {
            ($0.element, palette[$0.offset % palette.count])
        })
    }
}

struct UsageStatsView: View {
    let provider: String
    let title: String
    let pet: [String]
    let accent: Color
    let theme: PanelTheme
    let clusterNodes: [ClusterNodeRecord]
    let onBack: () -> Void

    @State private var range: StatsRange = .week
    @State private var rows: [DailyModelUsage] = []
    @State private var loaded = false
    @State private var hoveredBucket: String?
    @State private var selectedNodeID = ""

    var body: some View {
        let buckets = UsageStats.buckets(rows: rows, range: range)
        let order = UsageStats.modelOrder(buckets)
        let colors = UsageStats.colors(for: order)
        return VStack(spacing: 10) {
            header
            if clusterNodes.count > 1 { nodeFilter }
            if order.isEmpty {
                emptyState
            } else {
                chart(buckets: buckets, order: order, colors: colors)
                detail(buckets: buckets, order: order, colors: colors)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: load)
        .onChange(of: range) { value in
            Log.user("change \(provider) usage statistics range to \(value.rawValue)")
            hoveredBucket = nil
        }
        .onChange(of: selectedNodeID) { _ in
            hoveredBucket = nil
            load()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            PillButton(title: "返回", icon: "chevron.left", theme: theme, action: onBack)
            PixelPetView(art: pet, color: accent)
                .frame(width: 24, height: 17)
            Text("\(title) 用量统计")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Picker("", selection: $range) {
                ForEach(StatsRange.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)
        }
    }

    private var nodeFilter: some View {
        HStack(spacing: 6) {
            Image(systemName: "laptopcomputer.and.arrow.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            Text("数据来源")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Spacer()
            Picker("数据来源", selection: $selectedNodeID) {
                Text("全部 Mac").tag("")
                ForEach(clusterNodes) { node in
                    Text(node.name).tag(node.nodeID)
                }
            }
            .labelsHidden()
            .frame(width: 150)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar")
                .font(.system(size: 22))
                .foregroundStyle(theme.textTertiary)
            Text(loaded ? "暂无\(title)历史用量" : "正在读取用量数据…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Text("每日各模型的 token 用量会自动写入本地数据库")
                .font(.system(size: 9))
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private func chart(buckets: [StatsBucket], order: [String],
                       colors: [String: Color]) -> some View {
        let maxTotal = buckets.map(\.total).max() ?? 0
        let spacing: CGFloat = range == .month ? 2 : 4
        return VStack(spacing: 4) {
            HStack {
                Text("\(range.summaryTitle) · 共 \(UsageFormat.tokens(buckets.reduce(0) { $0 + $1.total })) tokens")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                if maxTotal > 0 {
                    Text("峰值 \(UsageFormat.tokens(maxTotal))")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(buckets) { bucket in
                    bar(bucket, maxTotal: maxTotal, order: order, colors: colors)
                }
            }
            .frame(height: 140)
            HStack(spacing: spacing) {
                ForEach(Array(buckets.enumerated()), id: \.element.id) { index, bucket in
                    Text(showsLabel(index: index, count: buckets.count) ? bucket.label : "")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func showsLabel(index: Int, count: Int) -> Bool {
        count <= 12 || index % 5 == 0 || index == count - 1
    }

    private func bar(_ bucket: StatsBucket, maxTotal: Int, order: [String],
                     colors: [String: Color]) -> some View {
        let total = bucket.total
        let chartHeight: CGFloat = 140
        let height = maxTotal > 0 ? chartHeight * CGFloat(total) / CGFloat(maxTotal) : 0
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            if total > 0 {
                VStack(spacing: 0) {
                    // 反转排序让总量最大的模型落在柱底
                    ForEach(order.reversed().filter { (bucket.models[$0] ?? 0) > 0 },
                            id: \.self) { model in
                        let tokens = bucket.models[model] ?? 0
                        let segmentHeight = max(1, height * CGFloat(tokens) / CGFloat(total))
                        ZStack {
                            Rectangle().fill(colors[model] ?? .gray)
                            if range != .month, segmentHeight >= 12 {
                                Text(Self.percentText(tokens, of: total))
                                    .font(.system(size: 7, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.95))
                                    .fixedSize()
                            }
                        }
                        .frame(height: segmentHeight)
                    }
                }
                .frame(height: max(2, height))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.progressTrack)
                    .frame(height: 3)
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(hoveredBucket == nil || hoveredBucket == bucket.id ? 1 : 0.4)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hoveredBucket = bucket.id
            } else if hoveredBucket == bucket.id {
                hoveredBucket = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredBucket)
    }

    private func detail(buckets: [StatsBucket], order: [String],
                        colors: [String: Color]) -> some View {
        let selected = hoveredBucket.flatMap { id in buckets.first { $0.id == id } }
        var models: [String: Int] = [:]
        if let selected {
            models = selected.models
        } else {
            for bucket in buckets {
                for (model, tokens) in bucket.models { models[model, default: 0] += tokens }
            }
        }
        let total = models.values.reduce(0, +)
        let heading = selected.map { "\($0.label) · \(UsageFormat.tokens($0.total)) tokens" }
            ?? "\(range.summaryTitle)模型占比 · 悬停柱状图看明细"
        return VStack(alignment: .leading, spacing: 5) {
            Text(heading)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            if total == 0 {
                Text("该时段无用量")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.textTertiary)
            }
            ForEach(order.filter { (models[$0] ?? 0) > 0 }, id: \.self) { model in
                let tokens = models[model] ?? 0
                HStack(spacing: 5) {
                    Circle().fill(colors[model] ?? .gray).frame(width: 6, height: 6)
                    Text(model)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(UsageFormat.tokens(tokens))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                    Text(Self.percentText(tokens, of: total))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func percentText(_ tokens: Int, of total: Int) -> String {
        guard total > 0 else { return "0%" }
        return "\(Int((Double(tokens) / Double(total) * 100).rounded()))%"
    }

    /// 选中的节点若已离开集群，则回退为全部 Mac，避免统计停留在已消失节点上
    private var effectiveNodeID: String? {
        clusterNodes.contains { $0.nodeID == selectedNodeID } ? selectedNodeID : nil
    }

    private func load() {
        let since = StatusService.dayKey(
            StatusService.aggregationCalendar.date(byAdding: .day, value: -366, to: Date()) ?? Date())
        let provider = provider
        let nodeID = effectiveNodeID
        loaded = false
        DispatchQueue.global(qos: .userInitiated).async {
            let result = nodeID.map {
                UsageStore.shared.clusterUsage(provider: provider, since: since, nodeID: $0)
            } ?? UsageStore.shared.usage(provider: provider, since: since)
            DispatchQueue.main.async {
                guard nodeID == effectiveNodeID else { return }
                rows = result
                loaded = true
            }
        }
    }
}
