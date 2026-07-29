import Foundation

/// 从 lighthouse 拿到的一个节点。
struct MeshRosterHost: Equatable {
    var name: String
    var overlay: String
    /// lighthouse 日志里这个节点最后一次握手/拆隧道的时间。仅作上下文：nebula 只记
    /// 状态变化，所以这里沉默表示隧道稳定，不代表节点消失。
    var lastActivityAt: Int
    /// lighthouse 自己探测的结果。nil 表示它没探测过（或探不了），与探测失败不同。
    var lighthouseReachable: Bool?
    var lighthouseRttUs: Int?
}

/// 结合两个观测点后对某节点的结论。
enum MeshState: String {
    /// 本机能到达
    case online
    /// lighthouse 能到达而本机不能：设备是活的，坏的是本机到它的那条隧道
    case tunnelDown = "tunnel_down"
    /// 两个观测点都到不了
    case offline
    /// 本机到不了，且 lighthouse 没有意见，暂时无法归因
    case unreachable
}

/// 一个节点，聚合好可直接渲染。
struct MeshHostView: Equatable {
    var name: String
    var overlay: String
    var state: MeshState
    /// 本轮探测的往返值，与窗口平均值不同：“当前”一列的意义就在于它可以和背后
    /// 那一小时不一致。
    var latestRttUs: UInt32?
    var samples = 0
    var okSamples = 0
    var rttMinUs: Int?
    var rttMaxUs: Int?
    var rttSumUs = 0
    /// lighthouse 自己的往返值。本机到不了对方时展示，它是“判隧道坏而不是判设备坏”
    /// 的依据。
    var lighthouseRttUs: Int?

    var rttAvgUs: Int? { okSamples > 0 ? rttSumUs / okSamples : nil }
    var lostSamples: Int { max(0, samples - okSamples) }
}

/// 本机视角的 nebula overlay。
///
/// 与 Multi-Host Sync 刻意分开：那边是“和我共享用量的那几台”（装了本应用并配对过），
/// 这边是“VPN 上的每一台设备”（凡是有证书的，绝大多数永远不会跑本应用）。用集群同步
/// 去测网格，等于让小集合冒充大集合，而且量到的是局域网路径而不是隧道。
final class MeshMonitor: ObservableObject {
    private static let lighthouseKey = "elink_mesh_lighthouse_url"

    /// 采集器发布名册的地址，例如 `http://192.168.100.200:8767`。
    /// 留空则关闭网格视图：没有名册就没有设备清单可探。
    static var lighthouse: String {
        get { UserDefaults.standard.string(forKey: lighthouseKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: lighthouseKey) }
    }

    /// 允许省略 scheme：面板里手输地址时补全比报错友好。
    static func lighthouseURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: normalized), url.host != nil else { return nil }
        return url
    }

    @Published private(set) var hosts: [MeshHostView] = []
    /// 一次名册拉取失败后置 false；视图继续用上一次的名册，lighthouse 重启不该让
    /// 整个网格视图变空。
    @Published private(set) var lighthouseReachable = false
    /// 完全打不开 ICMP socket 时为 false，UI 据此说明“测不了”，而不是把每台都画成掉线
    @Published private(set) var icmpAvailable = IcmpProbe.available()
    @Published private(set) var updatedAt: Date?

    private let store: UsageStore
    private var lighthouseURL: URL?
    private let windowSeconds: TimeInterval
    private let queue = DispatchQueue(label: "ai.elink.mesh-monitor", qos: .utility)
    private let session: URLSession
    private var timer: Timer?
    private var roster: [MeshRosterHost] = []

    init(store: UsageStore, lighthouseURL: URL?,
         windowSeconds: TimeInterval = 3600,
         session: URLSession = .shared) {
        self.store = store
        self.lighthouseURL = lighthouseURL
        self.windowSeconds = windowSeconds
        self.session = session
    }

    deinit { timer?.invalidate() }

    /// 换 lighthouse 地址后立刻生效。面板里改完还要重启应用才认，等于把一个
    /// 输入框做成了配置文件。
    func reconfigure(lighthouseURL: URL?, interval: TimeInterval = 30) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lighthouseURL = lighthouseURL
            self.roster = []
        }
        guard lighthouseURL != nil else {
            stop()
            publish(hosts: [], lighthouseReachable: false,
                    icmpAvailable: icmpAvailable, at: Date())
            return
        }
        start(interval: interval)
    }

    /// 三十秒既能让节点恢复很快可见，又不至于让网格本身变成一个流量来源。
    func start(interval: TimeInterval = 30) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.queue.async { self?.runOnce() }
        }
        queue.async { [weak self] in self?.runOnce() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 面板打开时补一轮，但只在数据确实旧了才补。
    ///
    /// 这张卡是「我怀疑出问题了」才会点开的，等满 30 秒常规节拍才看到答案，等于让它
    /// 诚实而不可用——年龄那行避免了误导，可要的答案还是得等。
    ///
    /// 守卫不能省：探测队列是串行的，一轮全网约四秒（不通的节点各占一次超时），反复
    /// 开关面板会把 sweep 排成队列，变成持续发包。
    func refreshIfStale(maxAge: TimeInterval = 10, now: Date = Date()) {
        guard lighthouseURL != nil, Self.isStale(updatedAt, maxAge: maxAge, now: now) else { return }
        queue.async { [weak self] in self?.runOnce() }
    }

    /// 从未探测过也算旧：那正是最需要补一轮的时候。
    static func isStale(_ updatedAt: Date?, maxAge: TimeInterval, now: Date = Date()) -> Bool {
        guard let updatedAt else { return true }
        return now.timeIntervalSince(updatedAt) >= maxAge
    }

    func runOnce(now: Date = Date()) {
        let fetched = fetchRoster()
        if let fetched { roster = fetched }
        let available = IcmpProbe.available()

        // 状态取本轮探测自己的结果，不从桶里读回：桶跨五分钟，刚掉线的节点会被读成
        // 还在线。
        var probed: [String: (MeshState, UInt32?)] = [:]
        if available {
            for (index, host) in roster.enumerated() {
                let rtt = IcmpProbe.ping(address: host.overlay, sequence: UInt16(index + 1))
                store.recordMeshSample(hostName: host.name, at: now, rttUs: rtt)
                probed[host.name] = (Self.classify(local: rtt,
                                                   lighthouseReachable: host.lighthouseReachable),
                                     rtt)
            }
        }

        let window = store.meshAggregates(since: now.addingTimeInterval(-windowSeconds))
        let views = roster.map { host -> MeshHostView in
            let aggregate = window[host.name]
            let (state, latest) = probed[host.name] ?? (.unreachable, nil)
            return MeshHostView(
                name: host.name, overlay: host.overlay,
                state: available ? state : .unreachable,
                latestRttUs: latest,
                samples: aggregate?.samples ?? 0,
                okSamples: aggregate?.okSamples ?? 0,
                rttMinUs: aggregate?.rttMinUs,
                rttMaxUs: aggregate?.rttMaxUs,
                rttSumUs: aggregate?.rttSumUs ?? 0,
                lighthouseRttUs: host.lighthouseRttUs
            )
        }
        publish(hosts: views, lighthouseReachable: fetched != nil,
                icmpAvailable: available, at: now)
    }

    /// 某节点的逐桶历史。同步读库：只在用户点开某一台时调用，一次十几行。
    func history(for hostName: String, window: TimeInterval = 6 * 3600) -> [MeshBucketPoint] {
        store.meshHistory(hostName: hostName, since: Date().addingTimeInterval(-window))
    }

    /// 本机探通就结束提问：无论 lighthouse 怎么看，本机能到达对方，而这正是用户在问的。
    static func classify(local: UInt32?, lighthouseReachable: Bool?) -> MeshState {
        if local != nil { return .online }
        switch lighthouseReachable {
        case .some(true): return .tunnelDown
        case .some(false): return .offline
        case .none: return .unreachable
        }
    }

    /// 解析 lighthouse 发布的名册。
    ///
    /// overlay 地址解析不出来的条目直接丢弃而不是猜：探测需要地址，编一个出来等于
    /// 报告一台不存在的设备。
    static func parseRoster(_ data: Data) -> [MeshRosterHost] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hosts = object["hosts"] as? [[String: Any]] else { return [] }
        return hosts.compactMap { host in
            guard let name = host["name"] as? String,
                  let overlay = host["overlay"] as? String,
                  overlay.withCString({ pointer -> Bool in
                      var address = in_addr()
                      return inet_pton(AF_INET, pointer, &address) == 1
                  }) else { return nil }
            let probedAt = host["probed_at"] as? Int
            let rtt = host["rtt_us"] as? Int
            return MeshRosterHost(
                name: name, overlay: overlay,
                lastActivityAt: host["last_activity_at"] as? Int ?? 0,
                lighthouseReachable: probedAt.map { _ in rtt != nil },
                lighthouseRttUs: rtt
            )
        }
    }

    /// 明文 HTTP，无鉴权，因此 lighthouse 侧只绑 overlay 地址：这份文档列出了每台
    /// 节点及其 WAN 地址，保护手段是只有 VPN 内能碰到那个端口。
    private func fetchRoster() -> [MeshRosterHost]? {
        guard let lighthouseURL else { return nil }
        var request = URLRequest(url: lighthouseURL)
        request.timeoutInterval = 5
        var result: [MeshRosterHost]?
        let waiter = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, _, _ in
            if let data { result = Self.parseRoster(data) }
            waiter.signal()
        }.resume()
        _ = waiter.wait(timeout: .now() + 8)
        guard let roster = result, !roster.isEmpty else { return nil }
        return roster
    }

    private func publish(hosts: [MeshHostView], lighthouseReachable: Bool,
                         icmpAvailable: Bool, at now: Date) {
        let apply = { [weak self] in
            guard let self else { return }
            self.hosts = hosts
            self.lighthouseReachable = lighthouseReachable
            self.icmpAvailable = icmpAvailable
            self.updatedAt = now
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }
}
