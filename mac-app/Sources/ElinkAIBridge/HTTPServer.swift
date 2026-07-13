import Foundation
import Network

final class HTTPServer {
    typealias Route = () -> (String, Data)
    typealias PostRoute = (Data) -> Data
    private let port: NWEndpoint.Port
    private let getRoutes: [String: Route]
    private let postRoutes: [String: PostRoute]
    private let queue = DispatchQueue(label: "elink.bridge.http")
    private var listener: NWListener?
    var onRequest: ((String, String) -> Void)?

    init(port: UInt16, get: [String: Route], post: [String: PostRoute]) {
        self.port = NWEndpoint.Port(rawValue: port)!
        getRoutes = get
        postRoutes = post
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, _ in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { connection.cancel() } else { self.receive(connection, accumulated: buffer) }
                return
            }
            let header = String(decoding: buffer[..<boundary.lowerBound], as: UTF8.self)
            let lines = header.split(whereSeparator: { $0.isNewline })
            let request = lines.first?.split(separator: " ") ?? []
            let method = request.count > 0 ? String(request[0]) : "GET"
            let rawPath = request.count > 1 ? String(request[1]) : "/"
            let path = rawPath.split(separator: "?").first.map(String.init) ?? rawPath
            let length = lines.first(where: { $0.lowercased().hasPrefix("content-length:") })
                .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
            let available = buffer.count - boundary.upperBound
            if method == "POST", available < length {
                self.receive(connection, accumulated: buffer); return
            }
            let end = min(buffer.count, boundary.upperBound + length)
            let body = buffer.subdata(in: boundary.upperBound..<end)
            self.respond(connection, method: method, path: path, body: body)
        }
    }

    private func respond(_ connection: NWConnection, method: String, path: String, body: Data) {
        if case let .hostPort(host, _) = connection.endpoint {
            let ip = String(host.debugDescription.split(separator: "%").first ?? "")
            onRequest?(path, ip)
        }
        let result: (Int, String, Data)
        if method == "GET", let route = getRoutes[path] {
            let (type, data) = route(); result = (200, type, data)
        } else if method == "POST", let route = postRoutes[path] {
            result = (200, "application/json", route(body))
        } else {
            result = (404, "application/json", Data("{\"error\":\"not found\"}".utf8))
        }
        let phrase = result.0 == 200 ? "OK" : "Not Found"
        let header = "HTTP/1.1 \(result.0) \(phrase)\r\nContent-Type: \(result.1)\r\nContent-Length: \(result.2.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + result.2,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
