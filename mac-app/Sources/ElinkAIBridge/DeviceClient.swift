import Foundation
import Darwin

final class DeviceClient {
    private static let hostKey = "elink_device_host"
    private static let seenKey = "elink_device_last_seen"

    static var host: String {
        get { UserDefaults.standard.string(forKey: hostKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: hostKey) }
    }
    static var lastSeenIP: String {
        get { UserDefaults.standard.string(forKey: seenKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: seenKey) }
    }
    static var baseURL: URL? {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return URL(string: value.hasPrefix("http") ? value : "http://\(value)")
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
        guard let url = URL(string: "http://\(candidate)/v1/device") else { completion(false); return }
        var request = URLRequest(url: url); request.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let valid = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .map { $0["device_type"] as? String == "elink-agent" } ?? false
            DispatchQueue.main.async { completion(valid) }
        }.resume()
    }

    static func autoPair(progress: @escaping (String) -> Void,
                         completion: @escaping (String?) -> Void) {
        var candidates = [String]()
        if !lastSeenIP.isEmpty { candidates.append("\(lastSeenIP):8766") }
        if !host.isEmpty, !candidates.contains(host) { candidates.append(host) }
        func next() {
            guard !candidates.isEmpty else { scanSubnet(progress: progress, completion: completion); return }
            let candidate = candidates.removeFirst()
            progress("验证 \(candidate)…")
            verify(candidate) { ok in
                if ok { host = candidate; completion(candidate) } else { next() }
            }
        }
        next()
    }

    private static func scanSubnet(progress: @escaping (String) -> Void,
                                   completion: @escaping (String?) -> Void) {
        guard let local = localIPv4(), let dot = local.lastIndex(of: ".") else { completion(nil); return }
        let prefix = local[..<dot]
        progress("扫描 \(prefix).1–254…")
        let group = DispatchGroup(), lock = NSLock(), limit = DispatchSemaphore(value: 32)
        var found: String?
        DispatchQueue.global(qos: .utility).async {
            for number in 1...254 {
                limit.wait(); group.enter()
                let candidate = "\(prefix).\(number):8766"
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
                if let found { host = found }
                completion(found)
            }
        }
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
        guard let base = baseURL else { completion(.failure(BridgeError.message("未设置设备地址"))); return }
        var request = URLRequest(url: base.appendingPathComponent(path)); request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<Data, Error>
            if let error { result = .failure(error) }
            else if let data, let response = response as? HTTPURLResponse,
                    (200...299).contains(response.statusCode) { result = .success(data) }
            else { result = .failure(BridgeError.message("设备响应失败")) }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private static func send(path: String, method: String, object: [String: Any],
                             completion: @escaping (Error?) -> Void) {
        guard let base = baseURL else { completion(BridgeError.message("未设置设备地址")); return }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method; request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: object)
        URLSession.shared.dataTask(with: request) { data, response, error in
            var result = error
            if result == nil, let response = response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode) {
                result = BridgeError.message(data.map { String(decoding: $0, as: UTF8.self) } ?? "HTTP \(response.statusCode)")
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}
