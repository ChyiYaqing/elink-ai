import AppKit

let port: UInt16 = 8765
let usageStore = UsageStore.shared
let usage = UsageFetcher(cacheStore: usageStore)
let status = StatusService(usage: usage, store: usageStore)
let server = HTTPServer(port: port, get: [
    "/": { ("application/json", status.snapshot().jsonData()) },
    "/v1/status": { ("application/json", status.snapshot().jsonData()) },
    "/v1/health": { ("application/json", Data("{\"ok\":true,\"schema_version\":1}".utf8)) },
], post: [
    "/v1/event": { body in
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let agent = object["agent"] as? String, let event = object["event"] as? String else {
            return Data("{\"ok\":false}".utf8)
        }
        status.recordEvent(agent: agent, event: event, message: object["message"] as? String)
        if ["Notification", "SessionStart", "SessionEnd", "Stop"].contains(event) {
            Log.info("hook \(agent): \(event)")
        }
        return Data("{\"ok\":true}".utf8)
    },
])
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
    Log.info("bridge v\(AppInfo.version) started on port \(port)")
} catch {
    Log.info("server start failed: \(error.localizedDescription)")
    let alert = NSAlert(); alert.messageText = "Elink AI Bridge 无法启动"
    alert.informativeText = "端口 \(port) 绑定失败：\(error.localizedDescription)"; alert.runModal()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let menu = MenuBarController(usage: usage, status: status, port: port)
_ = menu
usage.start()
app.run()
