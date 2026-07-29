import AppKit

let port: UInt16 = 8765
Log.info("application v\(AppInfo.version) launching")
do {
    try LaunchAtLogin.refreshIfEnabled()
} catch {
    Log.warning("refresh launch at login failed: \(error.localizedDescription)", category: "startup")
}
let usageStore = UsageStore.shared
let usage = UsageFetcher(cacheStore: usageStore)
let cluster = ClusterManager(store: usageStore)
let status = StatusService(usage: usage, store: usageStore, cluster: cluster)
// 出口 NAT 是本机属性，与集群同步无关，因此独立于 ClusterManager 驱动
let linkMonitor = LinkMonitor(store: usageStore, nodeID: { cluster.nodeID })
cluster.localStatusProvider = { status.localSnapshotForSync() }
// backfill 和时区重分桶共用一条串行队列：并发解析会读到可变的全局时区，产生混合桶。
// runUsageMaintenance 自查“已应用分桶时区”与当前时区，过期任务自然变成 no-op，
// 崩溃或跳过的迁移也会在下一次维护（包括下次启动）从正确起点重跑
let usageMaintenanceQueue = DispatchQueue(label: "ai.elink.usage-maintenance", qos: .utility)
cluster.onAggregationTimeZoneChange = {
    usageMaintenanceQueue.async { status.runUsageMaintenance() }
}
var routes = cluster.routes()
routes[HTTPRouteKey("GET", "/")] = { _ in .json(status.snapshot().jsonData()) }
routes[HTTPRouteKey("GET", "/v1/status")] = { _ in .json(status.snapshot().jsonData()) }
routes[HTTPRouteKey("GET", "/v1/health")] = { _ in
    .json(Data("{\"ok\":true,\"schema_version\":1}".utf8))
}
routes[HTTPRouteKey("POST", "/v1/event")] = { request in
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let agent = object["agent"] as? String, let event = object["event"] as? String else {
            return .json(Data("{\"ok\":false}".utf8), status: 400)
        }
        status.recordEvent(agent: agent, event: event, message: object["message"] as? String)
        if ["Notification", "SessionStart", "SessionEnd", "Stop"].contains(event) {
            Log.info("hook \(agent): \(event)")
        }
        return .json(Data("{\"ok\":true}".utf8))
}
let server = HTTPServer(port: port, routes: routes)
server.onRequest = { path, ip in
    guard DeviceClient.isEnabled,
          path == "/v1/status", !["127.0.0.1", "::1", ""].contains(ip) else { return }
    DeviceClient.recordDevicePoll(ip: ip)
    if DeviceClient.host.isEmpty {
        DeviceClient.host = "\(ip):8766"
        Log.info("device discovered at \(ip):8766")
    }
}
Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
    DeviceClient.healPairingIfNeeded(port: port)
}
// 回填历史用量到 SQLite（时区标记不一致时先完成重分桶迁移）；
// 此后每 5 分钟落一次今日数据，即使没有设备轮询也持续记录
usageMaintenanceQueue.async { status.runUsageMaintenance() }
Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
    // 迁移因瞬时文件/SQLite 错误失败时 marker 保持旧值，周期检测并重试。
    usageMaintenanceQueue.async { status.retryUsageMaintenanceIfNeeded() }
    DispatchQueue.global(qos: .utility).async { _ = status.snapshot() }
}
do {
    try server.start()
    cluster.start(port: port)
    Log.info("bridge v\(AppInfo.version) started on port \(port)")
} catch {
    Log.error("server start failed: \(error.localizedDescription)", category: "server")
    let alert = NSAlert(); alert.messageText = tr("Elink AI Bridge 无法启动", "Elink AI Bridge failed to start")
    alert.informativeText = tr("端口 \(port) 绑定失败：\(error.localizedDescription)",
                               "Port \(port) binding failed: \(error.localizedDescription)"); alert.runModal()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let menu = MenuBarController(usage: usage, status: status, cluster: cluster,
                             link: linkMonitor, port: port)
_ = menu
linkMonitor.start()
usage.start()
app.run()
