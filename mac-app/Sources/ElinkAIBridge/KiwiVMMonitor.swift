import Foundation

enum VpsVirtualization: String {
    case kvm, ovz, unknown
}

enum VpsRunState {
    case running, stopped, starting, suspended, unknown
}

/// 拉取失败的原因。每一种都要能分开告诉用户：把「api_key 被拒」说成「连不上」，
/// 会把一个去设置页两秒就能修好的问题引向排查网络。
enum VpsFetchError: Error, Equatable {
    /// 没拿到任何响应。KiwiVM 超出点数配额时也是直接丢请求，与断网不可区分。
    case unreachable
    /// HTTP 401/403，或 HTTP 200 但 JSON 里 `error` 非零。
    case rejected
    /// 拿到了响应，但不是一份 service info。
    case malformed
}

/// 一个「已用 / 总量」对。
///
/// 分子分母都留原始字节，百分比另存：文本要写真实数字——流量超额时那句
/// `1.2T / 1.1T` 必须看得见，而条自己会钳到 100。
struct VpsUsagePair: Equatable {
    let usedBytes: Int64
    let totalBytes: Int64

    /// 总量非正就没有这个读数。这是唯一的构造入口，除零在这里被挡掉，
    /// 而不是散落在每一个读百分比的地方。
    init?(used: Int64, total: Int64, clampUsed: Bool = true) {
        guard let total = KiwiVMMonitor.sanitizedBytes(total), total > 0,
              let used = KiwiVMMonitor.sanitizedBytes(used) else { return nil }
        self.totalBytes = total
        self.usedBytes = clampUsed ? min(used, total) : used
    }

    /// 可以大于 100：流量真的会超额。
    var usedPercent: Double { Double(usedBytes) / Double(totalBytes) * 100 }
}

/// 一台 VPS 的一次读数。
struct VpsSnapshot: Equatable {
    var veid: String
    var label: String
    var hostname: String
    var plan: String
    var location: String
    /// 截图里的 Node ID。
    var nodeAlias: String
    var nodeIP: String
    var ipAddresses: [String]
    var sshPort: Int?
    var os: String
    var vmType: VpsVirtualization
    var state: VpsRunState
    /// 原样保留。这串数字的格式由远端决定，解析成 Double 只会在格式变化时丢掉信息。
    var loadAverage: String?
    var cpuThrottled: Bool
    var memory: VpsUsagePair?
    var swap: VpsUsagePair?
    var disk: VpsUsagePair?
    var bandwidth: VpsUsagePair?
    var bandwidthResetAt: Date?
    /// 流量计费倍率。不等于 1 时详情页要说明，否则用户会拿配额去除自己实际传输的字节。
    var bandwidthMultiplier: Double
    var fetchedAt: Date

    var isRunning: Bool { state == .running }
    /// OVZ 的实时用量走另一套完全不同的结构，本版本不解析。
    var supportsLiveMetrics: Bool { vmType == .kvm }
}

/// KiwiVM 面板的只读镜像。
///
/// 与 `MeshMonitor` 同构，但生命周期刻意不同：那边常驻，因为它往 SQLite 落桶、详情页
/// 要画历史曲线，夜里没人看的时候正是最需要采样的时候；这边是一次性读数，没有历史图，
/// 面板关着时花掉的每一次调用都换不回任何东西——而 KiwiVM 的调用是计量的。所以轮询
/// 挂在面板开关上，`main.swift` 只负责构造。
final class KiwiVMMonitor: ObservableObject {
    struct HTTPResult {
        let data: Data
        let status: Int
    }

    @Published private(set) var servers: [VpsSnapshot] = []
    /// 配过没有。和「连不上」刻意分开：没配凭据的人不该被引去排查网络。
    @Published private(set) var configured: Bool
    /// veid → 上一次失败的原因。成功即清除。读数本身不清空，只标注它为什么是旧的。
    @Published private(set) var failures: [String: VpsFetchError] = [:]
    @Published private(set) var updatedAt: Date?

    private let queue = DispatchQueue(label: "ai.elink.kiwivm", qos: .utility)
    private let requestHandler: (URLRequest) -> HTTPResult?
    private var credentials: [VpsCredential]
    private var timer: Timer?
    /// 上一轮出过错时，下一轮不早于这个时刻。故障时反复开面板不该持续去打一个
    /// 已经在拒绝我们的接口。
    private var nextAllowed: Date?

    init(credentials: [VpsCredential],
         requestHandler: ((URLRequest) -> HTTPResult?)? = nil) {
        self.credentials = credentials
        self.configured = !credentials.isEmpty
        self.requestHandler = requestHandler ?? Self.performRequest
    }

    deinit { timer?.invalidate() }

    // MARK: - 生命周期

    /// 五分钟。一轮最坏 40 秒（两台各自可能吃满 20 秒超时），而这些数字——流量计数器、
    /// 磁盘占用——本来就不是按秒变化的。更密只会更快耗尽那份未公开的点数预算。
    func start(interval: TimeInterval = 300) {
        guard !credentials.isEmpty else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.queue.async { self?.runOnce() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func reconfigure(credentials: [VpsCredential], interval: TimeInterval = 300) {
        queue.async { [weak self] in
            guard let self else { return }
            self.credentials = credentials
            let known = Set(credentials.map(\.veid))
            DispatchQueue.main.async {
                self.configured = !credentials.isEmpty
                self.servers.removeAll { !known.contains($0.veid) }
                self.failures = self.failures.filter { known.contains($0.key) }
            }
        }
        guard !credentials.isEmpty else {
            stop()
            return
        }
        start(interval: interval)
        queue.async { [weak self] in self?.runOnce() }
    }

    /// 只换显示名，不发请求：名字是本地的，KiwiVM 那边什么都没变。
    /// `reconfigure` 会立刻补一轮，用在这里就是白花一次计量调用。
    func relabel(veid: String, to label: String) {
        queue.async { [weak self] in
            guard let self else { return }
            if let index = self.credentials.firstIndex(where: { $0.veid == veid }) {
                self.credentials[index].label = label
            }
            DispatchQueue.main.async {
                if let index = self.servers.firstIndex(where: { $0.veid == veid }) {
                    self.servers[index].label = label
                }
            }
        }
    }

    /// 面板打开时补一轮，但只在数据确实旧了才补。
    ///
    /// 两分钟远宽于 mesh 那边的十秒，因为这些读数以分钟为尺度变化——两分钟内再问一次，
    /// 得到的是同一个答案，代价却是一次计量调用。守卫本身不能省：一轮最坏 40 秒，
    /// 反复开关面板会把 15 秒级的请求排成队列。
    func refreshIfStale(maxAge: TimeInterval = 120, now: Date = Date()) {
        guard !credentials.isEmpty, Self.isStale(updatedAt, maxAge: maxAge, now: now) else { return }
        if let nextAllowed, now < nextAllowed { return }
        queue.async { [weak self] in self?.runOnce() }
    }

    /// 从未抓过也算旧：那正是最需要补一轮的时候。
    static func isStale(_ updatedAt: Date?, maxAge: TimeInterval, now: Date = Date()) -> Bool {
        guard let updatedAt else { return true }
        return now.timeIntervalSince(updatedAt) >= maxAge
    }

    // MARK: - 抓取

    /// 串行抓。并发能省下一台的等待，但那正是最容易同时撞上点数窗口的形状，
    /// 而且没有人在等这 15 秒。第一台的结果先上屏，不等第二台超时。
    func runOnce(now: Date = Date()) {
        var failed = false
        for credential in credentials {
            let result = fetch(credential: credential, now: now)
            switch result {
            case let .success(snapshot):
                publish(snapshot: snapshot, error: nil, at: Date())
            case let .failure(error):
                failed = true
                Log.warning("kiwivm veid=\(credential.veid) fetch failed: \(error)",
                            category: "kiwivm")
                publish(snapshot: nil, veid: credential.veid, error: error, at: Date())
            }
        }
        nextAllowed = failed ? Date().addingTimeInterval(120) : nil
    }

    /// 设置页保存前的那一次真实调用：验证通过才写 Keychain，而且这份快照直接上屏，
    /// 用户不必为看到第一行数字再等一个轮询周期，也不必多花一次调用。
    func probe(credential: VpsCredential,
               completion: @escaping (Result<VpsSnapshot, VpsFetchError>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.fetch(credential: credential, now: Date())
            if case let .success(snapshot) = result {
                self.publish(snapshot: snapshot, error: nil, at: Date())
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func fetch(credential: VpsCredential, now: Date) -> Result<VpsSnapshot, VpsFetchError> {
        guard let url = Self.liveServiceInfoURL(veid: credential.veid, apiKey: credential.apiKey) else {
            return .failure(.rejected)
        }
        var request = URLRequest(url: url)
        // 接口自称单次最长 15 秒，留五秒余量。
        request.timeoutInterval = 20
        return Self.parse(requestHandler(request), credential: credential, now: now)
    }

    private func publish(snapshot: VpsSnapshot?, veid: String? = nil,
                         error: VpsFetchError?, at date: Date) {
        let apply = { [weak self] in
            guard let self else { return }
            if let snapshot {
                if let index = self.servers.firstIndex(where: { $0.veid == snapshot.veid }) {
                    self.servers[index] = snapshot
                } else {
                    self.servers.append(snapshot)
                }
                self.servers = Self.ordered(self.servers, by: self.credentials)
            }
            let key = snapshot?.veid ?? veid
            if let key {
                if let error { self.failures[key] = error } else { self.failures.removeValue(forKey: key) }
            }
            self.updatedAt = date
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    /// 卡片上的顺序照用户在设置页里的顺序，而不是哪台先返回。
    static func ordered(_ servers: [VpsSnapshot], by credentials: [VpsCredential]) -> [VpsSnapshot] {
        let rank = Dictionary(credentials.enumerated().map { ($0.element.veid, $0.offset) },
                              uniquingKeysWith: { first, _ in first })
        return servers.sorted { (rank[$0.veid] ?? .max, $0.veid) < (rank[$1.veid] ?? .max, $1.veid) }
    }

    static func liveServiceInfoURL(veid: String, apiKey: String) -> URL? {
        guard let veid = KiwiVMCredentialStore.normalizedVeid(veid),
              let key = KiwiVMCredentialStore.normalizedApiKey(apiKey) else { return nil }
        var components = URLComponents(string: "https://api.64clouds.com/v1/getLiveServiceInfo")
        components?.queryItems = [
            URLQueryItem(name: "veid", value: veid),
            URLQueryItem(name: "api_key", value: key),
        ]
        return components?.url
    }

    private static func performRequest(_ request: URLRequest) -> HTTPResult? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: HTTPResult?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, let response = response as? HTTPURLResponse {
                result = HTTPResult(data: data, status: response.statusCode)
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return result
    }

    // MARK: - 解析
    //
    // 这份文档来自一个明文 HTTP 接口，而 Swift 的整数运算越界会直接 trap——一个
    // `Int.max` 就能把 app 打崩。所有数值都要先过 `number` 与 `sanitizedBytes`，
    // 所有乘法都要先除后比。`MeshMonitor.maxPlausibleRttUs` 立的就是同一条规矩。

    /// 任何字节量的上限。作用不是「多大算大」，而是划出一个做乘法不会溢出的取值域。
    static let maxPlausibleBytes: Int64 = 1 << 50

    static func parse(_ outcome: HTTPResult?, credential: VpsCredential,
                      now: Date) -> Result<VpsSnapshot, VpsFetchError> {
        guard let outcome else { return .failure(.unreachable) }
        if outcome.status == 401 || outcome.status == 403 { return .failure(.rejected) }
        guard (200...299).contains(outcome.status) else { return .failure(.unreachable) }
        // 一份 service info 只有几 KB。更大的东西不是我们要的文档。
        guard outcome.data.count <= 256 * 1024 else { return .failure(.malformed) }
        guard let object = try? JSONSerialization.jsonObject(with: outcome.data),
              let json = object as? [String: Any] else { return .failure(.malformed) }
        // HTTP 200 不代表成功：KiwiVM 把业务错误放在 body 里。
        if let error = number(json["error"]), error != 0 { return .failure(.rejected) }
        guard json["plan"] != nil || json["vm_type"] != nil else { return .failure(.malformed) }

        let vmType = VpsVirtualization(rawValue: text(json["vm_type"], max: 8)?.lowercased() ?? "")
            ?? .unknown
        let suspended = flag(json["suspended"])
        let hostname = text(json["live_hostname"], max: 128)
            ?? text(json["hostname"], max: 128) ?? ""

        return .success(VpsSnapshot(
            veid: credential.veid,
            label: credential.label,
            hostname: hostname,
            plan: text(json["plan"], max: 128) ?? "",
            location: text(json["node_location"], max: 64) ?? "",
            nodeAlias: text(json["node_alias"], max: 64) ?? "",
            nodeIP: text(json["node_ip"], max: 45) ?? "",
            ipAddresses: ipAddresses(json["ip_addresses"]),
            sshPort: port(json["ssh_port"]),
            os: text(json["os"], max: 128) ?? "",
            vmType: vmType,
            state: state(veStatus: text(json["ve_status"], max: 16), suspended: suspended),
            loadAverage: loadAverage(json["load_average"]),
            cpuThrottled: flag(json["is_cpu_throttled"]),
            memory: vmType == .kvm ? memory(json) : nil,
            swap: vmType == .kvm ? swap(json) : nil,
            disk: vmType == .kvm ? disk(json) : nil,
            bandwidth: bandwidth(json),
            bandwidthResetAt: resetDate(json["data_next_reset"], now: now),
            bandwidthMultiplier: multiplier(json["monthly_data_multiplier"]),
            fetchedAt: now
        ))
    }

    /// 一台被暂停的机器仍然可能报 `Running`，所以 `suspended` 压过 `ve_status`。
    static func state(veStatus: String?, suspended: Bool) -> VpsRunState {
        if suspended { return .suspended }
        switch veStatus?.lowercased() {
        case "running": return .running
        case "stopped": return .stopped
        case "starting": return .starting
        default: return .unknown
        }
    }

    /// 内存总量只有 `plan_ram` 一个来源（接口不给 `mem_total_kb`）。
    ///
    /// 已知偏差：`mem_available_kb` 是 guest 内的视角，内核保留会让它小于套餐值，
    /// 于是「已用」比真实占用高出几十 MB。KiwiVM 自己的面板也是这么算的，两边对得上
    /// 比各自「更准」重要。
    static func memory(_ json: [String: Any]) -> VpsUsagePair? {
        guard let total = sanitizedBytes(number(json["plan_ram"])),
              let available = kilobytes(json["mem_available_kb"]) else { return nil }
        return VpsUsagePair(used: max(0, total - available), total: total)
    }

    /// 分母用 `swap_total_kb` 而不是 `plan_swap`：KVM 上套餐字段常年是 0，而 guest
    /// 自己开了 swap 文件。截图那台 521 MB 就来自这里。
    static func swap(_ json: [String: Any]) -> VpsUsagePair? {
        guard let total = kilobytes(json["swap_total_kb"]), total > 0,
              let available = kilobytes(json["swap_available_kb"]) else { return nil }
        return VpsUsagePair(used: max(0, total - available), total: total)
    }

    /// 分母优先取当前实际生效的配额，套餐值只是回落。
    ///
    /// 平时两者相等（`[KVMV2-20G]` 的 `plan_disk` 是 21474836480，正好 20×2³⁰，
    /// 也说明这里的 GB 按 2³⁰ 算），但扩容或迁移之后会分叉——而「还能不能写下去」
    /// 这个问题的分母是眼下真的生效的那一个，不是套餐广告值。
    static func disk(_ json: [String: Any]) -> VpsUsagePair? {
        let quota = gigabytes(json["ve_disk_quota_gb"]).flatMap { $0 > 0 ? $0 : nil }
        guard let total = quota ?? sanitizedBytes(number(json["plan_disk"])),
              let used = sanitizedBytes(number(json["ve_used_disk_space_b"])) else {
            return nil
        }
        return VpsUsagePair(used: used, total: total)
    }

    /// 不乘 `monthly_data_multiplier`：倍率已经算进 `data_counter` 了，再乘一次会把
    /// 用量虚报成两倍。倍率本身另存，详情页说明它的存在。
    ///
    /// 超额不钳：`1.2T / 1.1T` 是这张卡最该说出口的一句话。
    static func bandwidth(_ json: [String: Any]) -> VpsUsagePair? {
        guard let total = sanitizedBytes(number(json["plan_monthly_data"])),
              let used = sanitizedBytes(number(json["data_counter"])) else { return nil }
        return VpsUsagePair(used: used, total: total, clampUsed: false)
    }

    static func multiplier(_ value: Any?) -> Double {
        guard let raw = double(value), raw.isFinite, raw > 0, raw <= 1000 else { return 1 }
        return raw
    }

    /// 只接受 now ± 400 天。越界的时间戳不会崩，但会在卡片上渲染出 1970 年——
    /// 一个看起来像 bug 的日期比没有日期更糟。
    static func resetDate(_ value: Any?, now: Date) -> Date? {
        guard let seconds = number(value), seconds > 0 else { return nil }
        let date = Date(timeIntervalSince1970: Double(seconds))
        let span: TimeInterval = 400 * 24 * 3600
        guard abs(date.timeIntervalSince(now)) <= span else { return nil }
        return date
    }

    static func port(_ value: Any?) -> Int? {
        guard let raw = number(value), (1...65535).contains(raw) else { return nil }
        return Int(raw)
    }

    /// 原样保留，只做长度与字符集清洗。这串东西的格式（`0.20 0.16 0.06 1/236 590404`）
    /// 由远端决定，拆成三个 Double 只会在格式变化那天把整行丢掉。
    static func loadAverage(_ value: Any?) -> String? {
        guard let raw = text(value, max: 32) else { return nil }
        let cleaned = raw.filter { $0.isNumber || $0 == "." || $0 == " " || $0 == "/" }
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func ipAddresses(_ value: Any?) -> [String] {
        guard let raw = value as? [Any] else { return [] }
        return raw.prefix(8).compactMap { text($0, max: 45) }.filter { !$0.isEmpty }
    }

    // MARK: - 宽松取值
    //
    // 这份 JSON 由 PHP 生成，类型不稳定：`is_cpu_throttled` 是 `"0"`/`"1"`，
    // `ve_disk_quota_gb` 和 `ssh_port` 有时也是字符串。逐字段 `as? Int` 会让某台机器的
    // 某个数字在某次响应里悄悄变成 nil，而 UI 上只表现为「这条进度条今天没了」。

    static func number(_ value: Any?) -> Int64? {
        switch value {
        case let value as Int64: return value
        case let value as Int: return Int64(value)
        case let value as Double:
            guard value.isFinite, value >= Double(Int64.min), value <= Double(Int64.max) else {
                return nil
            }
            return Int64(value)
        case let value as NSNumber: return number(value.doubleValue)
        case let value as String: return number(Double(value.trimmingCharacters(in: .whitespaces)))
        default: return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    static func text(_ value: Any?, max limit: Int) -> String? {
        let raw: String
        switch value {
        case let value as String: raw = value
        case let value as NSNumber: raw = value.stringValue
        default: return nil
        }
        let cleaned = raw.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(limit))
    }

    static func flag(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = number(value) { return value != 0 }
        return false
    }

    /// 负数、越界一律当作「没有这个读数」。少画一条进度条只是信息缺失，trap 是崩溃。
    static func sanitizedBytes(_ value: Int64?) -> Int64? {
        guard let value, value >= 0, value <= maxPlausibleBytes else { return nil }
        return value
    }

    /// 先除后比：`kb * 1024` 本身就是那个会溢出的乘法。
    static func kilobytes(_ value: Any?) -> Int64? {
        guard let kb = number(value), kb >= 0, kb <= maxPlausibleBytes / 1024 else { return nil }
        return kb * 1024
    }

    static func gigabytes(_ value: Any?) -> Int64? {
        let unit: Int64 = 1 << 30
        guard let gb = number(value), gb >= 0, gb <= maxPlausibleBytes / unit else { return nil }
        return gb * unit
    }
}
