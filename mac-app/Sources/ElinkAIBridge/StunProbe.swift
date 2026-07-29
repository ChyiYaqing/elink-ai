import Darwin
import Foundation

/// 一次 STUN 绑定观测的结果。
///
/// 判据取自排障笔记：本地端口与外部端口一致说明出口是保端口 NAT，本机因此位于
/// 端口争抢池里；不一致说明 NAT（或本机上的 TUN 代理）会重写源端口，该节点不参与
/// 争抢。两者都只是事实陈述，不存在哪个“正常”——保端口才是端口争抢的前提条件。
struct StunObservation: Equatable {
    var localPort: UInt16
    var externalAddress: String
    var externalPort: UInt16

    var portPreserved: Bool { localPort == externalPort }
    var externalEndpoint: String { "\(externalAddress):\(externalPort)" }
}

enum StunProbe {
    private static let magicCookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
    private static let bindingRequest: [UInt8] = [0x00, 0x01]
    private static let bindingSuccess: [UInt8] = [0x01, 0x01]
    private static let xorMappedAddress = 0x0020
    private static let familyIPv4: UInt8 = 0x01

    static func request(transactionID: Data) -> Data {
        var data = Data(bindingRequest)
        data.append(contentsOf: [0x00, 0x00]) // 没有属性，长度为 0
        data.append(contentsOf: magicCookie)
        data.append(transactionID)
        return data
    }

    /// 只解析 XOR-MAPPED-ADDRESS。事务 ID 不匹配的响应一律丢弃，避免把串到本
    /// socket 的其他 UDP 包当成回复。
    static func parseBinding(_ data: Data, transactionID: Data) -> (String, UInt16)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 20, transactionID.count == 12,
              Array(bytes[0..<2]) == bindingSuccess,
              Array(bytes[4..<8]) == magicCookie,
              Data(bytes[8..<20]) == transactionID else { return nil }
        let declared = Int(bytes[2]) << 8 | Int(bytes[3])
        let end = min(20 + declared, bytes.count)
        var offset = 20
        while offset + 4 <= end {
            let type = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let value = offset + 4
            guard value + length <= end else { return nil }
            if type == xorMappedAddress, length >= 8, bytes[value + 1] == familyIPv4 {
                let masked = UInt16(bytes[value + 2]) << 8 | UInt16(bytes[value + 3])
                let port = masked ^ 0x2112
                let octets = (0..<4).map { bytes[value + 4 + $0] ^ magicCookie[$0] }
                return (octets.map(String.init).joined(separator: "."), port)
            }
            // 属性值按 4 字节对齐填充
            offset = value + length + ((4 - length % 4) % 4)
        }
        return nil
    }

    /// 向一台 STUN 服务器发一个绑定请求并读回外部地址。
    /// 失败一律返回 nil：调用方负责在所有服务器都失败时显式降级。
    static func probe(host: String, port: UInt16 = 3478,
                      timeout: TimeInterval = 5) -> StunObservation? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var resolved: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &resolved) == 0,
              let address = resolved else { return nil }
        defer { freeaddrinfo(resolved) }

        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var limit = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit,
                   socklen_t(MemoryLayout<timeval>.size))

        let transactionID = Data((0..<12).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
        let payload = request(transactionID: transactionID)
        let sent = payload.withUnsafeBytes { buffer in
            sendto(descriptor, buffer.baseAddress, buffer.count, 0,
                   address.pointee.ai_addr, address.pointee.ai_addrlen)
        }
        guard sent == payload.count else { return nil }

        // 本地端口要在 sendto 之后取：socket 没有显式 bind，内核到这时才分配端口
        var local = sockaddr_in()
        var localLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &localLength) == 0
            }
        }
        let localPort = UInt16(bigEndian: local.sin_port)
        guard bound, localPort != 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: 1024)
        let received = recv(descriptor, &buffer, buffer.count, 0)
        guard received > 0,
              let binding = parseBinding(Data(buffer.prefix(received)),
                                         transactionID: transactionID) else { return nil }
        return StunObservation(localPort: localPort,
                               externalAddress: binding.0,
                               externalPort: binding.1)
    }
}
