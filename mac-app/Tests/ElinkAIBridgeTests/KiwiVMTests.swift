import XCTest
@testable import ElinkAIBridge

/// KiwiVM 面板镜像：凭据、解析、换算与失败归因。
final class KiwiVMTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(AppLanguage.chinese.rawValue, forKey: AppLanguage.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppLanguage.defaultsKey)
        super.tearDown()
    }

    // MARK: - 素材

    private static let gib: Int64 = 1 << 30
    private static let mib: Int64 = 1 << 20

    /// 截图那台 unreal-pod-1 的完整形状，含 KiwiVM 真实会发的字符串型数字。
    private func liveKVM(overrides: [String: Any] = [:],
                         removing keys: [String] = []) -> KiwiVMMonitor.HTTPResult {
        var json: [String: Any] = [
            "error": 0,
            "vm_type": "kvm",
            "ve_status": "Running",
            "plan": "KVMV2-20G",
            "node_location": "US, California",
            "node_alias": "v5921",
            "node_ip": "104.225.151.1",
            "ip_addresses": ["104.225.151.161"],
            "ssh_port": "22",
            "os": "Ubuntu 22.04 x86_64",
            "hostname": "unreal-pod-1.localdomain",
            "live_hostname": "unreal-pod-1",
            "load_average": "0.20 0.16 0.06 1/236 590404",
            "is_cpu_throttled": "0",
            "suspended": false,
            "plan_ram": 1_073_741_824,
            "mem_available_kb": 692_296,
            "swap_total_kb": 533_504,
            "swap_available_kb": 431_852,
            "plan_disk": 21_474_836_480,
            "ve_disk_quota_gb": "20",
            "ve_used_disk_space_b": 14_312_978_514,
            "data_counter": 289_974_716_989,
            "plan_monthly_data": 1_181_116_006_400,
            "monthly_data_multiplier": 1,
            "data_next_reset": 1_789_430_400,
        ]
        for key in keys { json.removeValue(forKey: key) }
        for (key, value) in overrides { json[key] = value }
        return result(json)
    }

    private func result(_ json: [String: Any], status: Int = 200) -> KiwiVMMonitor.HTTPResult {
        KiwiVMMonitor.HTTPResult(data: try! JSONSerialization.data(withJSONObject: json),
                                 status: status)
    }

    private let credential = VpsCredential(veid: "1575322", label: "unreal-pod-1",
                                           apiKey: String(repeating: "a", count: 64))

    private func parse(_ outcome: KiwiVMMonitor.HTTPResult?,
                       now: Date = Date(timeIntervalSince1970: 1_787_000_000))
        -> Result<VpsSnapshot, VpsFetchError> {
        KiwiVMMonitor.parse(outcome, credential: credential, now: now)
    }

    private func snapshot(_ outcome: KiwiVMMonitor.HTTPResult?,
                          now: Date = Date(timeIntervalSince1970: 1_787_000_000),
                          file: StaticString = #filePath, line: UInt = #line) throws -> VpsSnapshot {
        switch parse(outcome, now: now) {
        case let .success(snapshot): return snapshot
        case let .failure(error): XCTFail("解析失败：\(error)", file: file, line: line); throw error
        }
    }

    // MARK: - 主回归：面板上的每个数字都要对得上 KiwiVM 网页

    func testParsesTheScreenshotsKVMPayload() throws {
        let vps = try snapshot(liveKVM())

        XCTAssertEqual(vps.veid, "1575322")
        XCTAssertEqual(vps.hostname, "unreal-pod-1", "live_hostname 优先于 hostname")
        XCTAssertEqual(vps.plan, "KVMV2-20G")
        XCTAssertEqual(vps.location, "US, California")
        XCTAssertEqual(vps.nodeAlias, "v5921")
        XCTAssertEqual(vps.ipAddresses, ["104.225.151.161"])
        XCTAssertEqual(vps.sshPort, 22, "字符串型端口也要认")
        XCTAssertEqual(vps.os, "Ubuntu 22.04 x86_64")
        XCTAssertEqual(vps.state, .running)
        XCTAssertEqual(vps.loadAverage, "0.20 0.16 0.06 1/236 590404")
        XCTAssertFalse(vps.cpuThrottled)
        XCTAssertTrue(vps.supportsLiveMetrics)

        // 347.93 / 1024 MB
        XCTAssertEqual(Double(vps.memory!.usedBytes) / Double(Self.mib), 347.93, accuracy: 0.01)
        XCTAssertEqual(vps.memory?.totalBytes, 1024 * Self.mib)
        // 99.27 / 521 MB
        XCTAssertEqual(Double(vps.swap!.usedBytes) / Double(Self.mib), 99.27, accuracy: 0.01)
        XCTAssertEqual(Double(vps.swap!.totalBytes) / Double(Self.mib), 521, accuracy: 0.01)
        // 13.33 / 20 GB
        XCTAssertEqual(Double(vps.disk!.usedBytes) / Double(Self.gib), 13.33, accuracy: 0.01)
        XCTAssertEqual(vps.disk?.totalBytes, 20 * Self.gib)
        // 270.06 / 1100 GB
        XCTAssertEqual(Double(vps.bandwidth!.usedBytes) / Double(Self.gib), 270.06, accuracy: 0.01)
        XCTAssertEqual(vps.bandwidth?.totalBytes, 1100 * Self.gib)
        XCTAssertEqual(vps.bandwidth?.usedPercent ?? 0, 24.55, accuracy: 0.01)

        let reset = try XCTUnwrap(vps.bandwidthResetAt)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: reset),
                       DateComponents(year: 2026, month: 9, day: 15))
    }

    // MARK: - 换算里的取舍

    /// guest 视角的可用内存可能超过套餐值（内核保留、气球驱动）。已用不能是负数。
    func testMemoryNeverGoesNegativeWhenAvailableExceedsPlan() throws {
        let vps = try snapshot(liveKVM(overrides: ["mem_available_kb": 2_000_000]))
        XCTAssertEqual(vps.memory?.usedBytes, 0)
        XCTAssertEqual(vps.memory?.totalBytes, 1024 * Self.mib)
    }

    /// KVM 上 `plan_swap` 常年是 0，分母只能信 `swap_total_kb`；它为 0 时没有这个读数，
    /// 而不是一次除零。
    func testZeroSwapYieldsNoPairInsteadOfDividingByZero() throws {
        let vps = try snapshot(liveKVM(overrides: ["swap_total_kb": 0, "plan_swap": 536_870_912]))
        XCTAssertNil(vps.swap)
    }

    /// 扩容后套餐值与实际配额分叉，分母要取实际生效的那个。
    func testDiskTotalPrefersTheEnforcedQuota() throws {
        let grown = try snapshot(liveKVM(overrides: ["ve_disk_quota_gb": 40]))
        XCTAssertEqual(grown.disk?.totalBytes, 40 * Self.gib)

        let fallback = try snapshot(liveKVM(removing: ["ve_disk_quota_gb"]))
        XCTAssertEqual(fallback.disk?.totalBytes, 20 * Self.gib, "缺失时回落 plan_disk")

        let zeroed = try snapshot(liveKVM(overrides: ["ve_disk_quota_gb": 0]))
        XCTAssertEqual(zeroed.disk?.totalBytes, 20 * Self.gib, "0 不是一个配额")

        let neither = try snapshot(liveKVM(removing: ["ve_disk_quota_gb", "plan_disk"]))
        XCTAssertNil(neither.disk)
    }

    /// 倍率已经算进 data_counter 了。再乘一次会把配额说成两倍，用量看起来凭空减半。
    func testTrafficMultiplierIsRecordedButNotApplied() throws {
        let vps = try snapshot(liveKVM(overrides: ["monthly_data_multiplier": 2]))
        XCTAssertEqual(vps.bandwidth?.totalBytes, 1100 * Self.gib)
        XCTAssertEqual(vps.bandwidthMultiplier, 2)
    }

    /// 超额是真实状态，不能被钳成刚好 100%——那正是最需要看见的一行。
    func testTrafficOverQuotaKeepsTheRealNumbers() throws {
        let vps = try snapshot(liveKVM(overrides: ["data_counter": 1200 * Self.gib]))
        XCTAssertEqual(vps.bandwidth?.usedBytes, 1200 * Self.gib)
        XCTAssertGreaterThan(vps.bandwidth?.usedPercent ?? 0, 100)
    }

    /// 磁盘和内存不同：已用超过总量说明这份文档不自洽，钳住而不是照抄。
    func testDiskUsedIsClampedToTheQuota() throws {
        let vps = try snapshot(liveKVM(overrides: ["ve_used_disk_space_b": 99 * Self.gib]))
        XCTAssertEqual(vps.disk?.usedBytes, 20 * Self.gib)
    }

    // MARK: - 状态

    func testSuspendedOverridesAReportedRunningStatus() throws {
        let vps = try snapshot(liveKVM(overrides: ["suspended": true]))
        XCTAssertEqual(vps.state, .suspended)
    }

    func testStoppedVMKeepsItsIdentityWithoutSSHPort() throws {
        let vps = try snapshot(liveKVM(overrides: ["ve_status": "Stopped"],
                                       removing: ["ssh_port", "load_average"]))
        XCTAssertEqual(vps.state, .stopped)
        XCTAssertNil(vps.sshPort)
        XCTAssertNil(vps.loadAverage)
        XCTAssertEqual(vps.plan, "KVMV2-20G", "停机不该抹掉身份信息")
        XCTAssertNotNil(vps.bandwidth, "流量计数器与开关机无关")
    }

    /// OVZ 的实时用量在 `vz_status` / `vz_quota` 里，结构完全不同，本版本不解析。
    /// 但套餐、位置、流量这些来自 getServiceInfo 的字段对 OVZ 一样有效。
    func testOvzKeepsIdentityAndDropsLiveMetrics() throws {
        let vps = try snapshot(liveKVM(overrides: ["vm_type": "ovz"]))
        XCTAssertFalse(vps.supportsLiveMetrics)
        XCTAssertNil(vps.memory)
        XCTAssertNil(vps.swap)
        XCTAssertNil(vps.disk)
        XCTAssertNotNil(vps.bandwidth)
        XCTAssertEqual(vps.plan, "KVMV2-20G")
    }

    func testCpuThrottleFlagReadsTheStringForm() throws {
        XCTAssertTrue(try snapshot(liveKVM(overrides: ["is_cpu_throttled": "1"])).cpuThrottled)
        XCTAssertTrue(try snapshot(liveKVM(overrides: ["is_cpu_throttled": 1])).cpuThrottled)
        XCTAssertFalse(try snapshot(liveKVM(overrides: ["is_cpu_throttled": "0"])).cpuThrottled)
    }

    // MARK: - 失败归因

    func testNoResponseIsUnreachableRatherThanMalformed() {
        XCTAssertEqual(parse(nil), .failure(.unreachable))
    }

    func testUnauthorizedStatusIsRejected() {
        XCTAssertEqual(parse(result(["error": 0], status: 401)), .failure(.rejected))
        XCTAssertEqual(parse(result(["error": 0], status: 403)), .failure(.rejected))
    }

    /// KiwiVM 把业务错误放在 HTTP 200 的 body 里。当成一份空快照会让面板显示
    /// 一台什么都没有的机器，而真正的问题是密钥错了。
    func testApiErrorFieldAtHTTP200BecomesRejected() {
        XCTAssertEqual(parse(result(["error": 1, "message": "Invalid API credentials"])),
                       .failure(.rejected))
    }

    func testUnrelatedDocumentIsMalformed() {
        XCTAssertEqual(parse(result(["error": 0, "hello": "world"])), .failure(.malformed))
        XCTAssertEqual(parse(KiwiVMMonitor.HTTPResult(data: Data("not json".utf8), status: 200)),
                       .failure(.malformed))
    }

    func testOversizedBodyIsRejectedBeforeParsing() {
        let huge = KiwiVMMonitor.HTTPResult(data: Data(count: 256 * 1024 + 1), status: 200)
        XCTAssertEqual(parse(huge), .failure(.malformed))
    }

    // MARK: - 恶意与畸形输入
    //
    // 这份文档来自明文 HTTP，Swift 的整数越界会直接 trap。这一组的要求不是「算得对」，
    // 而是「无论对面发什么都不崩」。

    func testAbsurdNumbersAreDroppedInsteadOfTrapping() throws {
        let poisoned = try snapshot(liveKVM(overrides: [
            "plan_ram": Int64.max,
            "mem_available_kb": Int64.max,
            "swap_total_kb": -1,
            "plan_disk": -21_474_836_480,
            "ve_disk_quota_gb": "99999999999999",
            "ve_used_disk_space_b": "not a number",
            // JSON 里写不出 inf，但一个字符串数字可以任意长——这正是它会进来的形状。
            "data_counter": "1e400",
            "plan_monthly_data": 0,
        ]))
        XCTAssertNil(poisoned.memory)
        XCTAssertNil(poisoned.swap)
        XCTAssertNil(poisoned.disk)
        XCTAssertNil(poisoned.bandwidth)
        XCTAssertEqual(poisoned.state, .running, "算不出来的读数不该拖垮身份字段")
    }

    func testOverlongStringsAreTruncated() throws {
        let vps = try snapshot(liveKVM(overrides: [
            "os": String(repeating: "x", count: 5000),
            "node_location": String(repeating: "y", count: 5000),
            "load_average": String(repeating: "9", count: 5000),
        ]))
        XCTAssertEqual(vps.os.count, 128)
        XCTAssertEqual(vps.location.count, 64)
        XCTAssertEqual(vps.loadAverage?.count, 32)
    }

    func testAddressListIsCapped() throws {
        let vps = try snapshot(liveKVM(overrides: [
            "ip_addresses": Array(repeating: "10.0.0.1", count: 40),
        ]))
        XCTAssertEqual(vps.ipAddresses.count, 8)
    }

    func testImplausibleResetDatesAreDropped() {
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        XCTAssertNil(KiwiVMMonitor.resetDate(0, now: now))
        XCTAssertNil(KiwiVMMonitor.resetDate(1e18, now: now))
        XCTAssertNil(KiwiVMMonitor.resetDate(1, now: now), "1970 年的重置日只会让人以为是 bug")
        XCTAssertNotNil(KiwiVMMonitor.resetDate(1_789_430_400, now: now))
    }

    func testPortsOutsideTheValidRangeAreDropped() {
        XCTAssertNil(KiwiVMMonitor.port(0))
        XCTAssertNil(KiwiVMMonitor.port(70000))
        XCTAssertNil(KiwiVMMonitor.port("ssh"))
        XCTAssertEqual(KiwiVMMonitor.port("2222"), 2222)
    }

    /// PHP 生成的 JSON 里同一个字段会在整数、浮点和字符串之间摇摆。
    func testNumberAcceptsEveryFormKiwiVMActuallySends() {
        XCTAssertEqual(KiwiVMMonitor.number(347), 347)
        XCTAssertEqual(KiwiVMMonitor.number(347.0), 347)
        XCTAssertEqual(KiwiVMMonitor.number("347"), 347)
        XCTAssertEqual(KiwiVMMonitor.number(" 347 "), 347)
        XCTAssertNil(KiwiVMMonitor.number("abc"))
        XCTAssertNil(KiwiVMMonitor.number(nil))
        XCTAssertNil(KiwiVMMonitor.number(Double.infinity))
        XCTAssertNil(KiwiVMMonitor.number(Double.nan))
    }

    func testByteConversionsRefuseToOverflow() {
        XCTAssertNil(KiwiVMMonitor.kilobytes(Int64.max))
        XCTAssertNil(KiwiVMMonitor.gigabytes(Int64.max))
        XCTAssertNil(KiwiVMMonitor.sanitizedBytes(-1))
        XCTAssertNil(KiwiVMMonitor.sanitizedBytes(KiwiVMMonitor.maxPlausibleBytes + 1))
        XCTAssertEqual(KiwiVMMonitor.kilobytes(1024), 1_048_576)
        XCTAssertEqual(KiwiVMMonitor.gigabytes(20), 20 * Self.gib)
    }

    // MARK: - URL 与凭据

    func testLiveServiceInfoURLCarriesBothCredentials() throws {
        let url = try XCTUnwrap(KiwiVMMonitor.liveServiceInfoURL(veid: "1575322", apiKey: "key-\(String(repeating: "a", count: 20))"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "api.64clouds.com")
        XCTAssertEqual(components.path, "/v1/getLiveServiceInfo")
        XCTAssertEqual(components.queryItems?.first { $0.name == "veid" }?.value, "1575322")
        XCTAssertNotNil(components.queryItems?.first { $0.name == "api_key" }?.value)
    }

    func testLiveServiceInfoURLRefusesUnusableCredentials() {
        XCTAssertNil(KiwiVMMonitor.liveServiceInfoURL(veid: "not-a-veid", apiKey: String(repeating: "a", count: 64)))
        XCTAssertNil(KiwiVMMonitor.liveServiceInfoURL(veid: "1575322", apiKey: "short"))
    }

    func testNormalizedVeidAcceptsOnlyDigits() {
        XCTAssertEqual(KiwiVMCredentialStore.normalizedVeid("  1575322 \n"), "1575322")
        XCTAssertNil(KiwiVMCredentialStore.normalizedVeid(""))
        XCTAssertNil(KiwiVMCredentialStore.normalizedVeid("v5921"))
        XCTAssertNil(KiwiVMCredentialStore.normalizedVeid("1575322 1575323"))
        XCTAssertNil(KiwiVMCredentialStore.normalizedVeid("1234567890123"))
        XCTAssertNil(KiwiVMCredentialStore.normalizedVeid("１５７５"), "全角数字不是 veid")
    }

    func testNormalizedApiKeyRejectsAccidentalInput() {
        let key = String(repeating: "a", count: 64)
        XCTAssertEqual(KiwiVMCredentialStore.normalizedApiKey("  \(key)\n"), key)
        XCTAssertNil(KiwiVMCredentialStore.normalizedApiKey("too-short"))
        XCTAssertNil(KiwiVMCredentialStore.normalizedApiKey("\(key) \(key)"))
        XCTAssertNil(KiwiVMCredentialStore.normalizedApiKey(String(repeating: "a", count: 513)))
    }

    func testNormalizedLabelFallsBackToTheVeid() {
        XCTAssertEqual(KiwiVMCredentialStore.normalizedLabel("   ", veid: "1575322"), "VPS 1575322")
        XCTAssertEqual(KiwiVMCredentialStore.normalizedLabel(" unreal-pod-1 ", veid: "1575322"),
                       "unreal-pod-1")
        XCTAssertEqual(KiwiVMCredentialStore.normalizedLabel(String(repeating: "n", count: 100),
                                                            veid: "1575322").count, 32)
    }

    // MARK: - 凭据存储

    private func credentialStore(_ name: String = UUID().uuidString)
        -> (KiwiVMCredentialStore, String) {
        let path = NSTemporaryDirectory() + "elink-kiwivm-\(name).db"
        try? FileManager.default.removeItem(atPath: path)
        return (KiwiVMCredentialStore(store: UsageStore(path: path)), path)
    }

    /// 凭据存在本机 usage.db 而不是 Keychain：这个应用是 ad-hoc 签名的，每次重新构建
    /// 二进制哈希都变，Keychain 会把每个新版本当成陌生程序，向用户索要登录密码。
    func testCredentialsRoundTripThroughLocalStorage() throws {
        let (store, path) = credentialStore()
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertTrue(store.load().isEmpty)

        let first = VpsCredential(veid: "111", label: "one", apiKey: String(repeating: "a", count: 32))
        let second = VpsCredential(veid: "222", label: "two", apiKey: String(repeating: "b", count: 32))
        try store.save(first)
        try store.save(second)
        XCTAssertEqual(store.load(), [first, second])
        XCTAssertEqual(store.servers().map(\.veid), ["111", "222"],
                       "给 UI 的那份只带名字和 VM ID")

        // 同一台再存一次是替换，不是追加。
        var replaced = second
        replaced.apiKey = String(repeating: "c", count: 32)
        replaced.label = "two-renamed"
        try store.save(replaced)
        XCTAssertEqual(store.load(), [first, replaced])

        try store.remove(veid: "111")
        XCTAssertEqual(store.load(), [replaced], "删一台不该动到另一台")

        try store.remove(veid: "222")
        XCTAssertTrue(store.load().isEmpty)
    }

    /// 改名只动名字：api_key 和顺序都要原样留着，否则改个名就得重新验证一遍。
    func testRenameKeepsTheKeyAndOrder() throws {
        let (store, path) = credentialStore()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = VpsCredential(veid: "111", label: "one", apiKey: String(repeating: "a", count: 32))
        let second = VpsCredential(veid: "222", label: "two", apiKey: String(repeating: "b", count: 32))
        try store.save(first)
        try store.save(second)

        XCTAssertEqual(try store.rename(veid: "111", to: "  VPS-US-1 "), "VPS-US-1")
        var renamed = first
        renamed.label = "VPS-US-1"
        XCTAssertEqual(store.load(), [renamed, second])

        XCTAssertEqual(try store.rename(veid: "222", to: ""), "VPS 222", "清空名字回落到 VM ID")
        XCTAssertEqual(store.servers().map(\.label), ["VPS-US-1", "VPS 222"])
    }

    /// 删到一台不剩要真的清空，而不是留下一份空记录。
    func testRemovingTheLastServerClearsStorage() throws {
        let (store, path) = credentialStore()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try store.save(VpsCredential(veid: "111", label: "one",
                                     apiKey: String(repeating: "a", count: 32)))
        try store.remove(veid: "111")
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertTrue(store.servers().isEmpty)
    }

    func testCredentialStoreEnforcesTheServerCap() throws {
        let (store, path) = credentialStore()
        defer { try? FileManager.default.removeItem(atPath: path) }

        for index in 1...KiwiVMCredentialStore.maxServers {
            try store.save(VpsCredential(veid: "\(900 + index)", label: "s\(index)",
                                         apiKey: String(repeating: "a", count: 32)))
        }
        XCTAssertThrowsError(
            try store.save(VpsCredential(veid: "999", label: "extra",
                                         apiKey: String(repeating: "a", count: 32)))
        ) { error in
            XCTAssertEqual(error as? KiwiVMCredentialError, .tooManyServers)
        }
    }

    /// 校验不能只挡在 UI 上：存进去一个空 key，面板会拿它去打一个注定被拒的请求。
    func testCredentialStoreRefusesUnusableCredentials() {
        let (store, path) = credentialStore()
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertThrowsError(
            try store.save(VpsCredential(veid: "v5921", label: "bad",
                                         apiKey: String(repeating: "a", count: 32)))
        ) { XCTAssertEqual($0 as? KiwiVMCredentialError, .invalidVeid) }
        XCTAssertThrowsError(
            try store.save(VpsCredential(veid: "111", label: "bad", apiKey: "short"))
        ) { XCTAssertEqual($0 as? KiwiVMCredentialError, .invalidApiKey) }
        XCTAssertTrue(store.load().isEmpty)
    }

    // MARK: - 抓取器

    func testFailureKeepsThePreviousReadingAndNamesTheReason() {
        var outcome: KiwiVMMonitor.HTTPResult? = liveKVM()
        let monitor = KiwiVMMonitor(credentials: [credential]) { _ in outcome }

        monitor.runOnce()
        XCTAssertEqual(monitor.servers.count, 1)
        XCTAssertEqual(monitor.servers.first?.plan, "KVMV2-20G")
        XCTAssertTrue(monitor.failures.isEmpty)

        outcome = nil
        monitor.runOnce()
        XCTAssertEqual(monitor.servers.first?.plan, "KVMV2-20G",
                       "一次网络抖动不该让这台机器从卡片上消失")
        XCTAssertEqual(monitor.failures["1575322"], .unreachable)

        outcome = liveKVM()
        monitor.runOnce()
        XCTAssertTrue(monitor.failures.isEmpty, "恢复后必须清掉旧的失败标注")
    }

    /// 一台的失败不该污染另一台的读数。
    func testOneFailingServerDoesNotAffectTheOther() {
        let healthy = VpsCredential(veid: "111", label: "healthy",
                                    apiKey: String(repeating: "a", count: 32))
        let broken = VpsCredential(veid: "222", label: "broken",
                                   apiKey: String(repeating: "b", count: 32))
        let monitor = KiwiVMMonitor(credentials: [healthy, broken]) { request in
            request.url?.query?.contains("veid=111") == true
                ? self.liveKVM()
                : self.result(["error": 1, "message": "nope"])
        }

        monitor.runOnce()
        XCTAssertEqual(monitor.servers.map(\.veid), ["111"])
        XCTAssertEqual(monitor.failures, ["222": .rejected])
    }

    /// 卡片顺序照设置页的顺序，而不是哪台先返回。
    func testServersRenderInTheConfiguredOrder() {
        let credentials = ["333", "111", "222"].map {
            VpsCredential(veid: $0, label: $0, apiKey: String(repeating: "a", count: 32))
        }
        let snapshots = ["111", "222", "333"].map { veid in
            VpsSnapshot(veid: veid, label: veid, hostname: "", plan: "", location: "",
                        nodeAlias: "", nodeIP: "", ipAddresses: [], sshPort: nil, os: "",
                        vmType: .kvm, state: .running, loadAverage: nil, cpuThrottled: false,
                        memory: nil, swap: nil, disk: nil, bandwidth: nil,
                        bandwidthResetAt: nil, bandwidthMultiplier: 1, fetchedAt: Date())
        }
        XCTAssertEqual(KiwiVMMonitor.ordered(snapshots, by: credentials).map(\.veid),
                       ["333", "111", "222"])
    }

    /// 改名立刻上屏，但不花一次计量调用；下一轮读数也要沿用新名字。
    func testRelabelUpdatesTheCardWithoutFetching() {
        var calls = 0
        let monitor = KiwiVMMonitor(credentials: [credential]) { _ in
            calls += 1
            return self.liveKVM()
        }
        monitor.runOnce()
        XCTAssertEqual(calls, 1)

        monitor.relabel(veid: "1575322", to: "VPS-US-2")
        let drained = expectation(description: "queue drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(calls, 1, "名字是本地的，不该为它去问 KiwiVM")
        XCTAssertEqual(monitor.servers.first?.label, "VPS-US-2")

        monitor.runOnce()
        XCTAssertEqual(monitor.servers.first?.label, "VPS-US-2", "下一轮不能把旧名字写回来")
    }

    func testRefreshIfStaleSkipsWhileTheReadingIsFresh() {
        var calls = 0
        let monitor = KiwiVMMonitor(credentials: [credential]) { _ in
            calls += 1
            return self.liveKVM()
        }
        monitor.runOnce()
        XCTAssertEqual(calls, 1)

        monitor.refreshIfStale(maxAge: 120)
        // 队列是异步的，给它一个明确的同步点而不是靠 sleep 碰运气。
        let drained = expectation(description: "queue drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(calls, 1, "两分钟内再问一次得到的是同一个答案，代价却是一次计量调用")
    }

    // MARK: - 文案

    /// 陈旧必须可见：五分钟前的「运行中」和刚读到的长得一模一样。
    func testSubtitleAlwaysStatesTheAgeOfTheReading() {
        let now = Date()
        XCTAssertEqual(VpsCard.subtitle(total: 2, running: 2, updatedAt: nil, now: now),
                       "2 台 · 均在运行 · 尚未读取")
        XCTAssertEqual(VpsCard.subtitle(total: 2, running: 2,
                                        updatedAt: now.addingTimeInterval(-40), now: now),
                       "2 台 · 均在运行 · 40 秒前")
        XCTAssertEqual(VpsCard.subtitle(total: 2, running: 1,
                                        updatedAt: now.addingTimeInterval(-300), now: now),
                       "2 台 · 1 台在运行 · 5 分钟前")
    }

    /// 每一种反常都要有自己的一句话，尤其是「密钥被拒」不能被说成网络问题。
    func testNoticeNamesEachReasonDistinctly() throws {
        let running = try snapshot(liveKVM())
        XCTAssertNil(VpsCard.notice(for: running, failure: nil))

        let rejected = try XCTUnwrap(VpsCard.notice(for: running, failure: .rejected))
        XCTAssertTrue(rejected.contains("API key"), "被拒必须指向凭据，而不是网络")
        XCTAssertFalse(rejected.contains("连不上"))

        let unreachable = try XCTUnwrap(VpsCard.notice(for: running, failure: .unreachable))
        XCTAssertTrue(unreachable.contains("点数"),
                      "KiwiVM 限流时同样不回包，这句话必须容得下那种可能")
        XCTAssertNotEqual(unreachable, rejected)

        XCTAssertNotEqual(VpsCard.notice(for: running, failure: .malformed), unreachable)

        let stopped = try snapshot(liveKVM(overrides: ["ve_status": "Stopped"]))
        XCTAssertEqual(VpsCard.notice(for: stopped, failure: nil), "已停止 · 无实时读数")

        let suspended = try snapshot(liveKVM(overrides: ["suspended": true]))
        XCTAssertEqual(VpsCard.notice(for: suspended, failure: nil), "KiwiVM 报告此服务被暂停")

        let ovz = try snapshot(liveKVM(overrides: ["vm_type": "ovz"]))
        XCTAssertTrue(try XCTUnwrap(VpsCard.notice(for: ovz, failure: nil)).contains("OVZ"))

        let throttled = try snapshot(liveKVM(overrides: ["is_cpu_throttled": "1"]))
        XCTAssertEqual(VpsCard.notice(for: throttled, failure: nil), "CPU 正在被限流")
    }

    /// 「已用 / 总量」两个数必须同单位，否则读起来像是哪一边算错了。
    func testUsagePairRendersBothSidesInTheSameUnit() throws {
        let vps = try snapshot(liveKVM())
        XCTAssertEqual(VpsFormat.pair(try XCTUnwrap(vps.memory)), "347.93 / 1024M")
        XCTAssertEqual(VpsFormat.pair(try XCTUnwrap(vps.disk)), "13.33 / 20G")
        XCTAssertEqual(VpsFormat.pair(try XCTUnwrap(vps.bandwidth)), "270.06 / 1100G")
    }

    func testResetTextGivesBothTheDateAndTheDaysLeft() {
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        let text = VpsDetailView.resetText(Date(timeIntervalSince1970: 1_789_430_400), now: now)
        XCTAssertTrue(text.contains("还有"), "剩余天数才是看这一行的原因：\(text)")
        XCTAssertEqual(VpsDetailView.resetText(now.addingTimeInterval(60), now: now), "今天重置")
    }

    func testIsStaleTreatsNeverProbedAsStale() {
        let now = Date()
        XCTAssertTrue(KiwiVMMonitor.isStale(nil, maxAge: 120, now: now))
        XCTAssertFalse(KiwiVMMonitor.isStale(now.addingTimeInterval(-10), maxAge: 120, now: now))
        XCTAssertTrue(KiwiVMMonitor.isStale(now.addingTimeInterval(-200), maxAge: 120, now: now))
    }
}
