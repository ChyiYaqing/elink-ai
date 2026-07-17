import Foundation
import Network

struct HTTPRouteKey: Hashable {
    let method: String
    let path: String

    init(_ method: String, _ path: String) {
        self.method = method.uppercased()
        self.path = path
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
    let peer: String
}

struct HTTPResponse {
    let status: Int
    let contentType: String
    let body: Data

    static func json(_ body: Data, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json", body: body)
    }

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let data = (try? ClusterCrypto.encoder.encode(value)) ?? Data("{}".utf8)
        return json(data, status: status)
    }

    static func error(_ message: String, status: Int) -> HTTPResponse {
        json(["error": message], status: status)
    }
}

final class HTTPServer {
    typealias Route = (HTTPRequest) -> HTTPResponse
    private let port: NWEndpoint.Port
    private let routes: [HTTPRouteKey: Route]
    private let queue = DispatchQueue(label: "elink.bridge.http")
    private var listener: NWListener?
    var onRequest: ((String, String) -> Void)?

    init(port: UInt16, routes: [HTTPRouteKey: Route]) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.routes = routes
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        // Port conflicts surface asynchronously as a .failed state, e.g. when
        // an old bridge instance still holds the port during a restart. Retry
        // instead of leaving the app running without an HTTP server.
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Log.info("HTTP 服务已监听端口 \(self.port.rawValue)", category: "app")
            case let .failed(error):
                Log.error("HTTP 端口 \(self.port.rawValue) 监听失败：\(error)，5 秒后重试", category: "app")
                self.listener?.cancel()
                self.listener = nil
                self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    try? self?.start()
                }
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        // 每个连接只处理一次请求即关闭；整体超时防止慢速客户端长期占用连接
        queue.asyncAfter(deadline: .now() + 30) { connection.cancel() }
        receive(connection, accumulated: Data())
    }

    enum ParseOutcome: Equatable {
        case incomplete
        case invalid
        case complete(method: String, path: String, query: [String: String],
                      headers: [String: String], body: Data)

        static func == (lhs: ParseOutcome, rhs: ParseOutcome) -> Bool {
            switch (lhs, rhs) {
            case (.incomplete, .incomplete), (.invalid, .invalid):
                return true
            case let (.complete(lMethod, lPath, lQuery, lHeaders, lBody),
                      .complete(rMethod, rPath, rQuery, rHeaders, rBody)):
                return lMethod == rMethod && lPath == rPath && lQuery == rQuery
                    && lHeaders == rHeaders && lBody == rBody
            default:
                return false
            }
        }
    }

    static func parseRequest(from buffer: Data) -> ParseOutcome {
        guard buffer.count <= 1_100_000 else { return .invalid }
        guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return .incomplete
        }
        let header = String(decoding: buffer[..<boundary.lowerBound], as: UTF8.self)
        let lines = header.split(whereSeparator: { $0.isNewline })
        let requestLine = lines.first?.split(separator: " ") ?? []
        let method = requestLine.count > 0 ? String(requestLine[0]).uppercased() : "GET"
        let target = requestLine.count > 1 ? String(requestLine[1]) : "/"
        let components = URLComponents(string: target)
        let path = components?.path.isEmpty == false ? components!.path : "/"
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            headers[String(pair[0]).lowercased()] = pair[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0, length <= 1_000_000 else {
            return .invalid
        }
        let available = buffer.count - boundary.upperBound
        if available < length {
            return .incomplete
        }
        let body = buffer.subdata(in: boundary.upperBound..<(boundary.upperBound + length))
        return .complete(method: method, path: path, query: query, headers: headers, body: body)
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            switch Self.parseRequest(from: buffer) {
            case .invalid:
                connection.cancel()
            case .incomplete:
                if complete || error != nil { connection.cancel() }
                else { self.receive(connection, accumulated: buffer) }
            case let .complete(method, path, query, headers, body):
                self.respond(
                    connection,
                    method: method,
                    path: path,
                    query: query,
                    headers: headers,
                    body: body
                )
            }
        }
    }

    private func respond(_ connection: NWConnection, method: String, path: String,
                         query: [String: String], headers: [String: String], body: Data) {
        let startedAt = Date()
        var peer = "unknown"
        if case let .hostPort(host, _) = connection.endpoint {
            let ip = String(host.debugDescription.split(separator: "%").first ?? "")
            if !ip.isEmpty { peer = ip }
            if !ip.isEmpty { onRequest?(path, ip) }
        }
        let request = HTTPRequest(
            method: method, path: path, query: query, headers: headers, body: body, peer: peer
        )
        let response = routes[HTTPRouteKey(method, path)]?(request)
            ?? HTTPResponse.error("not found", status: 404)
        let phrase: String
        switch response.status {
        case 200: phrase = "OK"
        case 201: phrase = "Created"
        case 400: phrase = "Bad Request"
        case 401: phrase = "Unauthorized"
        case 403: phrase = "Forbidden"
        case 409: phrase = "Conflict"
        case 429: phrase = "Too Many Requests"
        default: phrase = response.status >= 500 ? "Internal Server Error" : "Not Found"
        }
        let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        Log.device(
            "bridge request \(method) \(path) peer=\(peer) status=\(response.status) request_bytes=\(body.count) response_bytes=\(response.body.count) duration_ms=\(duration)",
            level: (200...299).contains(response.status) ? .info : .warning
        )
        let header = "HTTP/1.1 \(response.status) \(phrase)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(
            content: Data(header.utf8) + response.body,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }
}
