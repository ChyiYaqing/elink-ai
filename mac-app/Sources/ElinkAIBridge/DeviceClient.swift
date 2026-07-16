import Foundation
import Darwin

final class DeviceClient {
    private static let hostKey = "elink_device_host"
    private static let seenKey = "elink_device_last_seen"
    private static let enabledKey = "elink_device_connection_enabled"
    private static let pairingLock = NSLock()
    private static var lastDevicePoll = Date.distantPast
    private static var healing = false
    private static var lastHealAttempt = Date.distantPast

    static var host: String {
        get { UserDefaults.standard.string(forKey: hostKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: hostKey) }
    }
    static var lastSeenIP: String {
        get { UserDefaults.standard.string(forKey: seenKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: seenKey) }
    }
    static var isEnabled: Bool {
        get { connectionEnabled(in: .standard) }
        set { setConnectionEnabled(newValue, in: .standard) }
    }
    static var baseURL: URL? {
        guard isEnabled else { return nil }
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return URL(string: value.hasPrefix("http") ? value : "http://\(value)")
    }

    static func connectionEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
    }

    static func setConnectionEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: enabledKey)
    }

    static func recordDevicePoll(ip: String) {
        guard isEnabled else { return }
        pairingLock.holding {
            lastDevicePoll = Date()
            lastSeenIP = ip
        }
    }

    static func fetchInfo(completion: @escaping (Result<DeviceInfo, Error>) -> Void) {
        get(path: "v1/device") { result in
            completion(result.flatMap { data in
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .failure(BridgeError.message("设备响应不是 JSON"))
                }
                do { return .success(try DeviceInfo(json: json)) }
                catch { return .failure(error) }
            })
        }
    }

    static func fetchPreview(completion: @escaping (Result<Data, Error>) -> Void) {
        get(path: "v1/preview.png", completion: completion)
    }

    static func setMode(_ mode: String, completion: @escaping (Error?) -> Void) {
        send(path: "v1/display/mode", method: "POST", object: ["mode": mode], completion: completion)
    }

    static func refresh(_ kind: String, completion: @escaping (Error?) -> Void) {
        send(path: "v1/display/refresh", method: "POST", object: ["kind": kind], completion: completion)
    }

    static func setBridge(_ url: String, completion: @escaping (Error?) -> Void) {
        send(path: "v1/config/bridge", method: "PUT", object: ["bridge_url": url], completion: completion)
    }

    static func verify(_ candidate: String, completion: @escaping (Bool) -> Void) {
        guard let base = candidateURL(candidate) else {
            Log.device("verify failed: invalid address \(candidate)", level: .warning)
            completion(false)
            return
        }
        let url = base.appendingPathComponent("v1/device")
        var request = URLRequest(url: url); request.timeoutInterval = 1.5
        let startedAt = Date()
        Log.device("request -> GET \(url.absoluteString) purpose=verify")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let valid = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .map { $0["device_type"] as? String == "elink-agent" } ?? false
            Log.device(responseLog(
                method: "GET", url: url, response: response, data: data,
                error: error, startedAt: startedAt, suffix: " valid=\(valid)"
            ), level: valid ? responseLevel(response: response, error: error) : .warning)
            DispatchQueue.main.async { completion(valid) }
        }.resume()
    }

    static func autoPair(progress: @escaping (String) -> Void,
                         completion: @escaping (String?) -> Void) {
        guard isEnabled else { completion(nil); return }
        var candidates = [String]()
        if !lastSeenIP.isEmpty { candidates.append("\(lastSeenIP):8766") }
        let configured = normalizedHost(host)
        if !configured.isEmpty, !candidates.contains(configured) { candidates.append(configured) }
        func next() {
            guard isEnabled else { completion(nil); return }
            guard !candidates.isEmpty else {
                Log.user("device auto-pair scanning local subnet")
                scanSubnet(progress: progress, completion: completion)
                return
            }
            let candidate = candidates.removeFirst()
            progress("验证 \(candidate)…")
            verify(candidate) { ok in
                guard isEnabled else { completion(nil); return }
                if ok { host = candidate; completion(candidate) } else { next() }
            }
        }
        next()
    }

    private static func scanSubnet(progress: @escaping (String) -> Void,
                                   completion: @escaping (String?) -> Void) {
        guard let local = localIPv4(), let dot = local.lastIndex(of: ".") else {
            Log.warning("auto-pair failed: local IPv4 unavailable", category: "device")
            completion(nil)
            return
        }
        let prefix = local[..<dot]
        progress("扫描 \(prefix).1–254…")
        let group = DispatchGroup(), lock = NSLock(), limit = DispatchSemaphore(value: 32)
        var found: String?
        DispatchQueue.global(qos: .utility).async {
            for number in 1...254 {
                limit.wait(); group.enter()
                let candidate = "\(prefix).\(number):8766"
                if candidate == "\(local):8766" { limit.signal(); group.leave(); continue }
                guard let url = URL(string: "http://\(candidate)/v1/device") else {
                    limit.signal(); group.leave(); continue
                }
                var request = URLRequest(url: url); request.timeoutInterval = 0.8
                URLSession.shared.dataTask(with: request) { data, _, _ in
                    let valid = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                        .map { $0["device_type"] as? String == "elink-agent" } ?? false
                    if valid { lock.holding { if found == nil { found = candidate } } }
                    limit.signal(); group.leave()
                }.resume()
            }
            group.notify(queue: .main) {
                guard isEnabled else { completion(nil); return }
                if let found { host = found }
                Log.device(
                    found.map { "auto-pair scan found \($0)" }
                        ?? "auto-pair scan completed: no device found",
                    level: found == nil ? .warning : .info
                )
                completion(found)
            }
        }
    }

    static func healPairingIfNeeded(port: UInt16) {
        guard isEnabled else { return }
        let shouldHeal = pairingLock.holding { () -> Bool in
            guard Date().timeIntervalSince(lastDevicePoll) > 180,
                  !healing,
                  Date().timeIntervalSince(lastHealAttempt) > 300 else { return false }
            healing = true
            lastHealAttempt = Date()
            return true
        }
        guard shouldHeal else { return }

        autoPair(progress: { _ in }) { found in
            guard found != nil else { finishHealing(); return }
            fetchInfo { result in
                guard case let .success(info) = result,
                      let local = localIPv4() else { finishHealing(); return }
                let desired = "http://\(local):\(port)"
                guard info.bridgeURL != desired, info.stale || info.bridgeURL.isEmpty else {
                    finishHealing(); return
                }
                setBridge(desired) { error in
                    if let error {
                        Log.warning("bridge self-heal failed: \(error.localizedDescription)", category: "device")
                    } else {
                        Log.device("bridge self-heal updated bridge URL")
                    }
                    finishHealing()
                }
            }
        }
    }

    static func normalizedHost(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("http://") { result.removeFirst("http://".count) }
        if result.hasPrefix("https://") { result.removeFirst("https://".count) }
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }

    private static func candidateURL(_ candidate: String) -> URL? {
        let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return URL(string: value.hasPrefix("http") ? value : "http://\(value)")
    }

    private static func finishHealing() {
        pairingLock.holding { healing = false }
    }

    static func localIPv4() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }
        var fallback: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = pointer.pointee
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  item.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: item.ifa_name), value = String(cString: host)
            if name == "en0" { return value }
            fallback = fallback ?? value
        }
        return fallback
    }

    private static func get(path: String, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let base = baseURL else {
            Log.warning("request GET \(path) failed: device address is not configured", category: "device")
            completion(.failure(BridgeError.message("未设置设备地址")))
            return
        }
        let url = base.appendingPathComponent(path)
        var request = URLRequest(url: url); request.timeoutInterval = 5
        let startedAt = Date()
        Log.device("request -> GET \(url.absoluteString)")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<Data, Error>
            if let error { result = .failure(error) }
            else if let data, let response = response as? HTTPURLResponse,
                    (200...299).contains(response.statusCode) { result = .success(data) }
            else { result = .failure(BridgeError.message("设备响应失败")) }
            Log.device(responseLog(
                method: "GET", url: url, response: response, data: data,
                error: error, startedAt: startedAt
            ), level: responseLevel(response: response, error: error))
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private static func send(path: String, method: String, object: [String: Any],
                             completion: @escaping (Error?) -> Void) {
        guard let base = baseURL else {
            Log.warning("request \(method) \(path) failed: device address is not configured", category: "device")
            completion(BridgeError.message("未设置设备地址"))
            return
        }
        let url = base.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method; request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: object)
        let startedAt = Date()
        Log.device("request -> \(method) \(url.absoluteString) body_bytes=\(request.httpBody?.count ?? 0)")
        URLSession.shared.dataTask(with: request) { data, response, error in
            var result = error
            if result == nil, let response = response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode) {
                result = BridgeError.message(data.map { String(decoding: $0, as: UTF8.self) } ?? "HTTP \(response.statusCode)")
            }
            Log.device(responseLog(
                method: method, url: url, response: response, data: data,
                error: result, startedAt: startedAt
            ), level: responseLevel(response: response, error: result))
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private static func responseLog(method: String, url: URL, response: URLResponse?,
                                    data: Data?, error: Error?, startedAt: Date,
                                    suffix: String = "") -> String {
        let milliseconds = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        let status = (response as? HTTPURLResponse)?.statusCode
        if let error {
            return "response <- \(method) \(url.absoluteString) status=\(status.map(String.init) ?? "-") bytes=\(data?.count ?? 0) duration_ms=\(milliseconds) error=\(error.localizedDescription)\(suffix)"
        }
        return "response <- \(method) \(url.absoluteString) status=\(status.map(String.init) ?? "-") bytes=\(data?.count ?? 0) duration_ms=\(milliseconds)\(suffix)"
    }

    private static func responseLevel(response: URLResponse?, error: Error?) -> Log.Level {
        guard error == nil,
              let status = (response as? HTTPURLResponse)?.statusCode,
              (200...299).contains(status) else { return .warning }
        return .info
    }
}
