import AppKit

let port: UInt16 = 8765
Log.info("application v\(AppInfo.version) launching")
let usageStore = UsageStore.shared
let usage = UsageFetcher(cacheStore: usageStore)
let cluster = ClusterManager(store: usageStore)
let status = StatusService(usage: usage, store: usageStore, cluster: cluster)
cluster.localStatusProvider = { status.localSnapshotForSync() }
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
    guard path == "/v1/status", !["127.0.0.1", "::1", ""].contains(ip) else { return }
    DeviceClient.recordDevicePoll(ip: ip)
    if DeviceClient.host.isEmpty {
        DeviceClient.host = "\(ip):8766"
        Log.info("device discovered at \(ip):8766")
    }
}
Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
    DeviceClient.healPairingIfNeeded(port: port)
}
// 回填历史用量到 SQLite；此后每 5 分钟落一次今日数据，即使没有设备轮询也持续记录
DispatchQueue.global(qos: .utility).async { status.backfillHistory() }
Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
    DispatchQueue.global(qos: .utility).async { _ = status.snapshot() }
}
do {
    try server.start()
    cluster.start(port: port)
    Log.info("bridge v\(AppInfo.version) started on port \(port)")
} catch {
    Log.error("server start failed: \(error.localizedDescription)", category: "server")
    let alert = NSAlert(); alert.messageText = "Elink AI Bridge 无法启动"
    alert.informativeText = "端口 \(port) 绑定失败：\(error.localizedDescription)"; alert.runModal()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let menu = MenuBarController(usage: usage, status: status, cluster: cluster, port: port)
_ = menu
usage.start()
app.run()
