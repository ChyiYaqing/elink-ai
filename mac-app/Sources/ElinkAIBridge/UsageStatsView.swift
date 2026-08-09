import Combine
import SwiftUI

enum StatsRange: String, CaseIterable {
    case day, week, month, year

    var title: String {
        switch self {
        case .day: return tr("日", "Day")
        case .week: return tr("周", "Week")
        case .month: return tr("月", "Month")
        case .year: return tr("年", "Year")
        }
    }

    var summaryTitle: String {
        switch self {
        case .day: return tr("今日", "Today")
        case .week: return tr("近 7 天", "Last 7 days")
        case .month: return tr("近 30 天", "Last 30 days")
        case .year: return tr("近 12 个月", "Last 12 months")
        }
    }
}

struct StatsBucket: Identifiable, Equatable {
    let id: String       // 日桶 "yyyy-MM-dd"，月桶 "yyyy-MM"
    let label: String
    let models: [String: Int]
    var total: Int { models.values.reduce(0, +) }
}

struct DeviceUsage: Identifiable, Equatable {
    let nodeID: String?          // nil = 无来源标记的本地行
    let models: [String: Int]
    var total: Int { models.values.reduce(0, +) }
    var id: String { nodeID ?? "" }
}

enum UsageStats {
    static func buckets(rows: [DailyModelUsage], range: StatsRange, now: Date = Date()) -> [StatsBucket] {
        let calendar = StatusService.aggregationCalendar
        var byDay: [String: [String: Int]] = [:]
        for row in rows {
            byDay[row.day, default: [:]][row.model, default: 0] += row.tokens
        }
        switch range {
        case .day:
            // 「日」档走 hourlyBuckets（小时表），不使用天粒度行
            return []
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
                let month = calendar.component(.month, from: date)
                let label = tr("\(month)月",
                    ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][month - 1])
                return StatsBucket(id: key, label: label, models: byMonth[key] ?? [:])
            }
        }
    }

    /// 「日」档的设备占比走小时行：那一档的图和明细都由小时行渲染，设备占比也必须
    /// 同源，否则同一屏上会出现两个对不上的总量。
    /// bucketID 非空时只统计那一个小时，与悬停某天/某月的口径一致。
    static func deviceTotals(hourly rows: [HourlyModelUsage],
                             bucketID: String? = nil) -> [DeviceUsage] {
        var byNode: [String?: [String: Int]] = [:]
        for row in rows {
            if let bucketID, String(format: "%02d", row.hour) != bucketID { continue }
            byNode[row.nodeID, default: [:]][row.model, default: 0] += row.tokens
        }
        return byNode
            .map { DeviceUsage(nodeID: $0.key, models: $0.value) }
            .sorted {
                $0.total == $1.total
                    ? ($0.nodeID ?? "") < ($1.nodeID ?? "")
                    : $0.total > $1.total
            }
    }

    /// 范围内各设备的 token 总量与模型明细，按总量降序（并列按 nodeID 升序保证稳定）。
    /// bucketID 非空时只统计该桶（悬停某天/某月），与 detail 的口径保持一致
    static func deviceTotals(rows: [DailyModelUsage], range: StatsRange,
                             now: Date = Date(), bucketID: String? = nil) -> [DeviceUsage] {
        // 复用 buckets 的时间窗口，保证设备总和与图表总量一致
        let keys = bucketID.map { Set([$0]) }
            ?? Set(buckets(rows: [], range: range, now: now).map(\.id))
        var byNode: [String?: [String: Int]] = [:]
        for row in rows {
            let key = range == .year ? String(row.day.prefix(7)) : row.day
            guard keys.contains(key) else { continue }
            byNode[row.nodeID, default: [:]][row.model, default: 0] += row.tokens
        }
        return byNode
            .map { DeviceUsage(nodeID: $0.key, models: $0.value) }
            .sorted {
                $0.total == $1.total
                    ? ($0.nodeID ?? "") < ($1.nodeID ?? "")
                    : $0.total > $1.total
            }
    }

    /// 今日 0-23 时的小时桶，固定 24 个，id "00".."23"
    static func hourlyBuckets(rows: [HourlyModelUsage]) -> [StatsBucket] {
        var byHour: [Int: [String: Int]] = [:]
        for row in rows {
            byHour[row.hour, default: [:]][row.model, default: 0] += row.tokens
        }
        return (0..<24).map { hour in
            StatsBucket(id: String(format: "%02d", hour), label: tr("\(hour)时", "\(hour)"),
                        models: byHour[hour] ?? [:])
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

    /// Token 分类的展示顺序、中文名与配色。色相沿用 Input 蓝 / Output 绿 /
    /// Cache Read 紫 / Cache Write 橙 / Reasoning 红的通用惯例，具体取值由主题给出。
    static var categoryOrder: [(key: String, label: String, color: Color)] {
        let colors = AppTheme.current.palette(dark: false).categoryPalette
        return zip([("input", tr("输入", "Input")),
                    ("output", tr("输出", "Output")),
                    ("cache_read", tr("缓存读取", "Cache Read")),
                    ("cache_write", tr("缓存写入", "Cache Write")),
                    ("reasoning", tr("推理", "Reasoning"))], colors)
            .map { (key: $0.0.0, label: $0.0.1, color: $0.1) }
    }

    /// 某个 day 键是否落在当前范围窗口内。
    /// 分类总量和金额必须共用这一套判断，否则面板上会出现「token 变了金额没跟着变」
    /// 这种对不上的组合——两份各自实现的窗口逻辑迟早会分叉。
    static func windowFilter(range: StatsRange, now: Date = Date()) -> (String) -> Bool {
        switch range {
        case .day:
            let today = StatusService.dayKey(now)
            return { $0 == today }
        case .week, .month, .year:
            let keys = Set(buckets(rows: [], range: range, now: now).map(\.id))
            let monthly = range == .year
            return { keys.contains(monthly ? String($0.prefix(7)) : $0) }
        }
    }

    /// 当前范围窗口内的 token 分类总量；分类数据仅本机、按天累积
    static func categoryTotals(rows: [DailyCategoryUsage], range: StatsRange,
                               now: Date = Date()) -> [String: Int] {
        let inWindow = windowFilter(range: range, now: now)
        var totals: [String: Int] = [:]
        for row in rows where inWindow(row.day) {
            totals[row.category, default: 0] += row.tokens
        }
        return totals
    }

    /// 当前范围窗口内的 API 等价成本（美元），以及其中没有定价、因而未计入的模型。
    ///
    /// 这不是账单：日常用量走订阅，额度内并不按 token 收费。它回答的是
    /// 「同样这些量走官方 API 要花多少」，展示时必须照这个口径措辞。
    static func costTotal(rows: [ModelCategoryUsage], range: StatsRange,
                          now: Date = Date(),
                          table: [String: ModelPricing] = Pricing.table())
        -> (cost: Double, unpriced: Set<String>, pricedTokens: Int) {
        let inWindow = windowFilter(range: range, now: now)
        let windowed = rows.filter { inWindow($0.day) }
        let result = Pricing.total(rows: windowed, table: table)
        let priced = windowed
            .filter { table[$0.model] != nil }
            .reduce(0) { $0 + $1.tokens }
        return (result.cost, result.unpriced, priced)
    }

    /// 金额覆盖了窗口内多大比例的 token。
    ///
    /// 分类明细可能缺席：还没升级的集群节点不发这份数据，历史回填也可能没跑完。
    /// 缺的那部分静静地不计入总额，金额就会比实际低而毫无征兆——所以覆盖率不足时
    /// 必须说出来。
    static func costCoverage(pricedTokens: Int, windowTokens: Int) -> Double {
        windowTokens > 0 ? min(1, Double(pricedTokens) / Double(windowTokens)) : 1
    }

    /// 金额文案。小额保留分位，超过 100 美元后分位没有意义，取整更好读。
    static func costText(_ cost: Double) -> String {
        cost >= 100 ? String(format: "$%.0f", cost) : String(format: "$%.2f", cost)
    }

    /// 堆叠条按模型着色的色位。数据序列色在明暗模式下取同一个值——同一个模型
    /// 在浅色和深色面板里必须是同一个颜色，否则跨屏对照就断了。
    static var palette: [Color] { AppTheme.current.palette(dark: false).dataPalette }

    static func colors(for order: [String]) -> [String: Color] {
        Dictionary(uniqueKeysWithValues: order.enumerated().map {
            ($0.element, palette[$0.offset % palette.count])
        })
    }

    /// 设备身份色。与模型配色分开：条形和图例点按模型着色，这一套只用在设备的图标
    /// 和占比徽章上，两者落在不同的视觉位置，不会互相冒充。
    static var devicePalette: [Color] { AppTheme.current.palette(dark: false).devicePalette }

    /// 设备占比区块的显示条件。
    ///
    /// 只要在集群里、又没有筛到单台，就给出占比，哪怕只有一台有用量。以前还要求
    /// 「至少两台有数据」，于是 Codex 这种只有一台在用的 provider 整块消失，而
    /// 「数据源」筛选器仍然显示——页面一边说这是多机环境，一边不给分布，读者只能
    /// 猜是坏了还是真没有。一张 100% 的卡片是个明确回答：其余机器没用过。
    ///
    /// 筛到单台时不显示：那时候占比只会是 100%，是同义反复。
    static func showsDeviceShare(clusterNodes: Int, filteredToOneHost: Bool,
                                 devicesWithUsage: Int) -> Bool {
        clusterNodes > 1 && !filteredToOneHost && devicesWithUsage > 0
    }

    /// 集群成员各自的身份色，按 nodeID 排序后依次取色。
    ///
    /// 先试过按 nodeID 哈希取色，实测四台机器里有三台撞成同一个颜色——6 个色位下
    /// 四台不撞的概率只有 28%，而「区分设备」正是这套颜色存在的理由。按排序位置分配
    /// 则在 6 台以内保证互不相同，且每台主机排出来的顺序一样，跨屏对照仍然成立。
    ///
    /// 代价是新增一台设备可能让排在它后面的颜色整体后移。成员变化是低频事件，
    /// 换来的是同一屏上永远不撞色。
    ///
    /// 取的是集群花名册而不是当前有用量的那几台：否则切一次时间范围，某台没用量的
    /// 设备一消失，剩下的颜色就会重排。
    static func deviceColors(for nodeIDs: [String]) -> [String: Color] {
        let ordered = Set(nodeIDs.filter { !$0.isEmpty }).sorted()
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map {
            ($0.element, devicePalette[$0.offset % devicePalette.count])
        })
    }

    /// 花名册之外的来源（尚未同步到的节点、无来源标记的本地行）落到哈希上：不保证
    /// 与别人不撞，但至少同一台设备每次都是同一个颜色。
    static func fallbackDeviceColor(_ nodeID: String?) -> Color {
        guard let nodeID, !nodeID.isEmpty else { return devicePalette[0] }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in nodeID.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return devicePalette[Int(hash % UInt64(devicePalette.count))]
    }
}

struct UsageStatsView: View {
    let provider: String
    let title: String
    let pet: [String]
    let accent: Color
    let theme: PanelTheme
    let clusterNodes: [ClusterNodeRecord]
    /// 默认是全局那一份。可注入是为了测试：渲染这个视图会读库，用共享实例就等于让
    /// 测试去开用户的真实数据库——读是小事，建表和写入不是。
    var store: UsageStore = .shared
    let onBack: () -> Void

    @State private var range: StatsRange = .week
    @State private var rows: [DailyModelUsage] = []
    @State private var hourlyRows: [HourlyModelUsage] = []
    @State private var categoryRows: [DailyCategoryUsage] = []
    @State private var modelCategoryRows: [ModelCategoryUsage] = []
    @State private var loaded = false
    @State private var hoveredBucket: String?
    @State private var selectedNodeID = ""

    var body: some View {
        let chartRows = effectiveNodeID.map { id in rows.filter { $0.nodeID == id } } ?? rows
        // 「日」档展示今日 24 小时分布，来源是小时行；其余档走天级行
        let chartHourly = effectiveNodeID.map { id in hourlyRows.filter { $0.nodeID == id } }
            ?? hourlyRows
        let buckets = range == .day
            ? UsageStats.hourlyBuckets(rows: chartHourly)
            : UsageStats.buckets(rows: chartRows, range: range)
        let order = UsageStats.modelOrder(buckets)
        let colors = UsageStats.colors(for: order)
        // 全范围的设备列表决定区块是否展示；悬停某个桶时明细跟随该桶，与 detail 口径一致
        let rangeDevices = range == .day
            ? UsageStats.deviceTotals(hourly: hourlyRows)
            : UsageStats.deviceTotals(rows: rows, range: range)
        let devices = hoveredBucket.map { bucket in
            range == .day
                ? UsageStats.deviceTotals(hourly: hourlyRows, bucketID: bucket)
                : UsageStats.deviceTotals(rows: rows, range: range, bucketID: bucket)
        } ?? rangeDevices
        return VStack(spacing: 10) {
            header
            if clusterNodes.count > 1 { nodeFilter }
            if order.isEmpty {
                emptyState
            } else {
                chart(buckets: buckets, order: order, colors: colors)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 10) {
                        detail(buckets: buckets, order: order, colors: colors)
                        categorySection(
                            UsageStats.categoryTotals(rows: categoryRows, range: range))
                        costSection(
                            UsageStats.costTotal(rows: modelCategoryRows, range: range),
                            // 与金额同一个窗口的 token 总量，用来判断覆盖了多少
                            windowTokens: buckets.reduce(0) { $0 + $1.total })
                        if UsageStats.showsDeviceShare(
                            clusterNodes: clusterNodes.count,
                            filteredToOneHost: effectiveNodeID != nil,
                            devicesWithUsage: rangeDevices.count
                        ) {
                            deviceSection(devices: devices, order: order, colors: colors,
                                          heading: deviceHeading(buckets))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { load() }
        // backfill、5 分钟采集或集群同步落库后自动刷新，不必关闭重开统计页
        .onReceive(
            NotificationCenter.default
                .publisher(for: UsageStore.dataDidChangeNotification)
                .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
        ) { _ in load(silent: true) }
        .onChange(of: range) { value in
            Log.user("change \(provider) usage statistics range to \(value.rawValue)")
            hoveredBucket = nil
        }
        .onChange(of: selectedNodeID) { _ in
            hoveredBucket = nil
        }
        .onChange(of: clusterNodes.map(\.nodeID)) { ids in
            // 选中的节点离开集群后清空选择，回退为全部主机
            if !selectedNodeID.isEmpty, !ids.contains(selectedNodeID) {
                selectedNodeID = ""
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                PillButton(title: tr("返回", "Back"), icon: "chevron.left", theme: theme, action: onBack)
                PixelPetView(art: pet, color: accent)
                    .frame(width: 24, height: 17)
                Text(tr("\(title) 用量统计", "\(title) Usage"))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
            }
            Picker("", selection: $range) {
                ForEach(StatsRange.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }

    private var nodeFilter: some View {
        HStack(spacing: 6) {
            Image(systemName: "laptopcomputer.and.arrow.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            Text(tr("数据来源", "Data Source"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Spacer()
            Picker(tr("数据来源", "Data Source"), selection: $selectedNodeID) {
                Text(tr("全部主机", "All Hosts")).tag("")
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
            Text(loaded ? tr("暂无\(title)历史用量", "No \(title) usage history yet")
                        : tr("正在读取用量数据…", "Loading usage data…"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Text(tr("每日各模型的 token 用量会自动写入本地数据库",
                    "Daily per-model token usage is saved to a local database automatically"))
                .font(.system(size: 9))
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private func chart(buckets: [StatsBucket], order: [String],
                       colors: [String: Color]) -> some View {
        let maxTotal = buckets.map(\.total).max() ?? 0
        let spacing: CGFloat = (range == .month || range == .day) ? 2 : 4
        return VStack(spacing: 4) {
            HStack {
                Text(tr("\(range.summaryTitle) · 共 \(UsageFormat.tokens(buckets.reduce(0) { $0 + $1.total })) tokens",
                        "\(range.summaryTitle) · \(UsageFormat.tokens(buckets.reduce(0) { $0 + $1.total })) tokens total"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                if maxTotal > 0 {
                    Text(tr("峰值 \(UsageFormat.tokens(maxTotal))", "Peak \(UsageFormat.tokens(maxTotal))"))
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
        if range == .day { return index % 6 == 0 || index == count - 1 }
        return count <= 12 || index % 5 == 0 || index == count - 1
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
                            if range != .month, range != .day, segmentHeight >= 12 {
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
            ?? tr("\(range.summaryTitle)模型占比 · 悬停柱状图看明细",
                  "\(range.summaryTitle) model share · hover bars for details")
        return VStack(alignment: .leading, spacing: 5) {
            Text(heading)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            if total == 0 {
                Text(tr("该时段无用量", "No usage in this period"))
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

    /// Token 分类区块：占比条 + 各分类数量与百分比。分类数据仅本机记录，
    /// 按官方 API 价折算的等价成本。措辞必须点明是折算：这些用量走的是订阅，
    /// 显示成「费用」会被当成已经扣过的钱。没有定价的模型要说出来，
    /// 否则残缺的总额会被当成全部。
    @ViewBuilder
    private func costSection(_ result: (cost: Double, unpriced: Set<String>, pricedTokens: Int),
                             windowTokens: Int) -> some View {
        let coverage = UsageStats.costCoverage(pricedTokens: result.pricedTokens,
                                               windowTokens: windowTokens)
        if result.cost > 0 || !result.unpriced.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(tr("\(range.summaryTitle) API 等价成本",
                            "\(range.summaryTitle) API-equivalent cost"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                    Text(UsageStats.costText(result.cost))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.textPrimary)
                }
                Text(tr("按官方 API 价折算，非订阅实际扣费",
                        "Converted at list API prices — not what your subscription charged"))
                    .font(.system(size: 8))
                    .foregroundStyle(theme.textTertiary)
                if coverage < 0.995 {
                    Text(tr(
                        "只覆盖了本区间 \(Int((coverage * 100).rounded()))% 的 token："
                            + "尚未升级的设备不提供分类明细，实际金额更高",
                        "Covers only \(Int((coverage * 100).rounded()))% of this range's tokens — "
                            + "devices not yet upgraded send no breakdown, so the real figure is higher"
                    ))
                    .font(.system(size: 8))
                    .foregroundStyle(theme.textTertiary)
                }
                if !result.unpriced.isEmpty {
                    Text(tr("未计入无公开定价的模型：\(result.unpriced.sorted().joined(separator: "、"))",
                            "Excludes models with no published price: "
                                + result.unpriced.sorted().joined(separator: ", ")))
                        .font(.system(size: 8))
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
    }

    /// 从启用后随 5 分钟采集按天累积，历史日期不回填
    @ViewBuilder
    private func categorySection(_ totals: [String: Int]) -> some View {
        let entries = UsageStats.categoryOrder.compactMap {
            item -> (label: String, color: Color, tokens: Int)? in
            guard let tokens = totals[item.key], tokens > 0 else { return nil }
            return (item.label, item.color, tokens)
        }
        let total = entries.reduce(0) { $0 + $1.tokens }
        if total > 0 {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("\(range.summaryTitle) Token 分类", "\(range.summaryTitle) token categories"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(entries.indices, id: \.self) { index in
                            Rectangle().fill(entries[index].color)
                                .frame(width: geo.size.width * CGFloat(entries[index].tokens)
                                    / CGFloat(max(1, total)))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 5)
                ForEach(entries.indices, id: \.self) { index in
                    let entry = entries[index]
                    HStack(spacing: 5) {
                        Circle().fill(entry.color).frame(width: 6, height: 6)
                        Text(entry.label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text(UsageFormat.tokens(entry.tokens))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.textTertiary)
                        Text(Self.categoryPercentText(entry.tokens, of: total))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 分类占比保留一位小数；缓存读取通常占绝对多数，整数百分比会把其余项挤成 0%
    static func categoryPercentText(_ tokens: Int, of total: Int) -> String {
        guard total > 0, tokens > 0 else { return "0%" }
        let percent = Double(tokens) / Double(total) * 100
        return percent < 0.1 ? "<0.1%" : String(format: "%.1f%%", percent)
    }

    /// 悬停某个桶时标题跟随该桶，与 detail 的标题口径一致
    private func deviceHeading(_ buckets: [StatsBucket]) -> String {
        let hovered = hoveredBucket.flatMap { id in buckets.first { $0.id == id } }
        return hovered.map { tr("\($0.label) 设备占比", "\($0.label) device share") }
            ?? tr("\(range.summaryTitle)设备占比", "\(range.summaryTitle) device share")
    }

    private func deviceSection(devices: [DeviceUsage], order: [String],
                               colors: [String: Color], heading: String) -> some View {
        let total = devices.reduce(0) { $0 + $1.total }
        let identities = UsageStats.deviceColors(for: clusterNodes.map(\.nodeID))
        return VStack(alignment: .leading, spacing: 6) {
            Text(heading)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            if devices.isEmpty {
                Text(tr("该时段无用量", "No usage in this period"))
                    .font(.system(size: 9))
                    .foregroundStyle(theme.textTertiary)
            }
            ForEach(devices) { device in
                deviceCard(device, order: order, colors: colors, clusterTotal: total,
                           identity: device.nodeID.flatMap { identities[$0] }
                               ?? UsageStats.fallbackDeviceColor(device.nodeID))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 每台设备一个身份色。原本图标和徽章都用 provider 的强调色，于是同一屏上的
    /// 几台机器长得一模一样，只能靠读名字区分。
    private func deviceCard(_ device: DeviceUsage, order: [String],
                            colors: [String: Color], clusterTotal: Int,
                            identity: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(identity)
                Text(deviceName(device.nodeID))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(UsageFormat.tokens(device.total))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                Text(Self.percentText(device.total, of: clusterTotal))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(identity)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(identity.opacity(theme.dark ? 0.22 : 0.12)))
            }
            // 迷你比例条：按模型着色，与上方模型图例配色一致
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(order.filter { (device.models[$0] ?? 0) > 0 }, id: \.self) { model in
                        Rectangle().fill(colors[model] ?? .gray)
                            .frame(width: geo.size.width * CGFloat(device.models[model] ?? 0)
                                / CGFloat(max(1, device.total)))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 4)
            ForEach(order.filter { (device.models[$0] ?? 0) > 0 }, id: \.self) { model in
                let tokens = device.models[model] ?? 0
                HStack(spacing: 5) {
                    Circle().fill(colors[model] ?? .gray)
                        .frame(width: 5, height: 5)
                    Text(model)
                        .font(.system(size: 9))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(UsageFormat.tokens(tokens))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                    // 该设备内的模型占比，而非全集群占比
                    Text(Self.percentText(tokens, of: device.total))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .padding(8)
        .sectionCard(theme)
    }

    private func deviceName(_ nodeID: String?) -> String {
        guard let nodeID else { return tr("本机", "This Host") }
        return clusterNodes.first { $0.nodeID == nodeID }?.name
            ?? tr("未知设备 \(nodeID.prefix(8))", "Unknown device \(nodeID.prefix(8))")
    }

    static func percentText(_ tokens: Int, of total: Int) -> String {
        guard total > 0 else { return "0%" }
        return "\(Int((Double(tokens) / Double(total) * 100).rounded()))%"
    }

    /// 选中的节点若已离开集群，则回退为全部主机，避免统计停留在已消失节点上
    private var effectiveNodeID: String? {
        clusterNodes.contains { $0.nodeID == selectedNodeID } ? selectedNodeID : nil
    }

    private func load(silent: Bool = false) {
        let since = StatusService.dayKey(
            StatusService.aggregationCalendar.date(byAdding: .day, value: -366, to: Date()) ?? Date())
        let provider = provider
        if !silent { loaded = false }
        let today = StatusService.dayKey(Date())
        // 集群启用时 usage() 返回全节点带 nodeID 的行，节点筛选在内存中完成
        DispatchQueue.global(qos: .userInitiated).async {
            let result = store.usage(provider: provider, since: since)
            let hourly = store.hourlyUsage(provider: provider, day: today)
            let categories = store.categoryUsage(provider: provider, since: since)
            let modelCategories = store.modelCategoryUsage(provider: provider, since: since)
            DispatchQueue.main.async {
                rows = result
                hourlyRows = hourly
                categoryRows = categories
                modelCategoryRows = modelCategories
                loaded = true
            }
        }
    }
}
