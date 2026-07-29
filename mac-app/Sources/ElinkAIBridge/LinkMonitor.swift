import Foundation

/// 周期性地用 STUN 判断本机出口的 NAT 行为。
///
/// 这测的是**出口是否保留源端口**，不是 nebula 某个端口此刻通不通。保端口 NAT 是
/// 端口争抢的前提条件，而端口争抢在 RTT 曲线上完全看不出来——它表现为某个节点整段
/// 消失而不是变慢，所以需要这条独立的判据。
final class LinkMonitor: ObservableObject {
    /// 当前观测；nil 表示尚未成功探测过
    @Published private(set) var observation: StunObservation?
    /// 所有服务器都失败时置为 true，UI 必须据此显式降级而不是留空
    @Published private(set) var unavailable = false

    static let defaultServers = [
        "stun.miwifi.com",
        "stun.l.google.com",
        "stun.cloudflare.com",
    ]

    private let store: UsageStore
    private let nodeID: () -> String
    private let servers: [String]
    private let probe: (String) -> StunObservation?
    private let queue = DispatchQueue(label: "ai.elink.link-monitor", qos: .utility)
    private var timer: Timer?
    private var lastPortPreserved: Bool?
    private var lastAvailable: Bool?

    init(store: UsageStore,
         nodeID: @escaping () -> String,
         servers: [String] = LinkMonitor.defaultServers,
         probe: @escaping (String) -> StunObservation? = { StunProbe.probe(host: $0) }) {
        self.store = store
        self.nodeID = nodeID
        self.servers = servers
        self.probe = probe
    }

    deinit { timer?.invalidate() }

    func start(interval: TimeInterval = 60) {
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

    /// 依次尝试每台服务器，第一个成功的即采用。
    /// 单台 STUN 服务器不可用不能让整条判据失效，这是它配多台的唯一原因。
    func runOnce(now: Date = Date()) {
        let current = servers.lazy.compactMap { self.probe($0) }.first
        guard let current else {
            recordUnavailable(at: now)
            return
        }
        let node = nodeID()
        let previousEndpoint = store.lastExternalEndpoint()
        store.setLastExternalEndpoint(current.externalEndpoint)

        if let previousEndpoint, previousEndpoint != current.externalEndpoint,
           !node.isEmpty,
           previousAddress(of: previousEndpoint) != current.externalAddress {
            // 只有外部 IP 变了才算重拨；端口变化在保端口 NAT 下每次探测都会发生
            store.recordLinkEvent(LinkEvent(
                occurredAt: now, nodeID: node, kind: .wanRebind,
                detail: "\(previousAddress(of: previousEndpoint) ?? "?") → \(current.externalAddress)"
            ))
        }

        // 首次观测不写事件，只建立基线；否则每次进程启动都会多一条状态记录
        if let lastPortPreserved, lastPortPreserved != current.portPreserved, !node.isEmpty {
            store.recordLinkEvent(LinkEvent(
                occurredAt: now, nodeID: node,
                kind: current.portPreserved ? .portPreserved : .portRewritten,
                detail: "\(current.localPort) → \(current.externalEndpoint)"
            ))
        }
        lastPortPreserved = current.portPreserved

        if lastAvailable == false, !node.isEmpty {
            Log.info("STUN probe recovered", category: "link")
        }
        lastAvailable = true
        publish { $0.observation = current; $0.unavailable = false }
    }

    private func recordUnavailable(at now: Date) {
        let node = nodeID()
        // 只在从可用跌到不可用时记一次，避免持续故障刷屏
        if lastAvailable != false, !node.isEmpty {
            store.recordLinkEvent(LinkEvent(
                occurredAt: now, nodeID: node, kind: .stunUnavailable,
                detail: servers.joined(separator: ", ")
            ))
            Log.warning("all STUN servers unreachable", category: "link")
        }
        lastAvailable = false
        publish { $0.unavailable = true }
    }

    private func previousAddress(of endpoint: String) -> String? {
        endpoint.split(separator: ":").first.map(String.init)
    }

    private func publish(_ apply: @escaping (LinkMonitor) -> Void) {
        if Thread.isMainThread { apply(self) }
        else { DispatchQueue.main.async { [weak self] in self.map(apply) } }
    }
}
