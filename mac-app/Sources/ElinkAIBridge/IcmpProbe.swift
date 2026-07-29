import Darwin
import Foundation

/// ICMP echo，用来直接测量 nebula overlay。
///
/// 不调用 `/sbin/ping`：它的参数在各平台上差异恰好落在最危险的地方——`-W` 在 macOS
/// 是毫秒、在 Linux 是秒，而且还要解析随语言变化的输出。
///
/// 依次尝试两种 socket，因为没有哪一种到处都能用：
/// - `SOCK_DGRAM` 完全不需要权限，但在 Linux 上受 `net.ipv4.ping_group_range` 管辖，
///   不少发行版把它设成空区间 `1 0`，那道闸门没有 capability 旁路，连 root 也会被拒。
/// - `SOCK_RAW` 在那种机器上可用，但需要 `CAP_NET_RAW`。
///
/// macOS 上第一种即可，这里保留降级只是为了和 elink-tui 的判据保持一致。
///
/// `SOCK_DGRAM` 下 identifier 字段归内核所有并会被改写，`SOCK_RAW` 则会把本机所有
/// ICMP 包（含其他进程的回复）一并交过来。用序号加载荷令牌匹配对两者都成立。
enum IcmpProbe {
    private static let echoType: UInt8 = 8
    private static let echoReply: UInt8 = 0
    private static let headerLength = 8
    /// 标记本进程自己的包，避免把内核因别的原因递过来的回复当成我们的往返
    private static let token = Array("elink-ai".utf8)

    /// 本进程能否打开 ICMP socket。调用方据此显式降级，而不是把全网报成不可达。
    static func available() -> Bool {
        guard let descriptor = openSocket() else { return false }
        close(descriptor)
        return true
    }

    private static func openSocket() -> Int32? {
        let unprivileged = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        if unprivileged >= 0 { return unprivileged }
        let raw = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)
        return raw >= 0 ? raw : nil
    }

    /// 构造带正确校验和的 echo request。
    /// Linux 会替 datagram ICMP socket 重算，macOS 不会，所以两边都自己算。
    static func echoRequest(sequence: UInt16) -> Data {
        var packet = [UInt8](repeating: 0, count: headerLength + token.count)
        packet[0] = echoType
        packet[6] = UInt8(sequence >> 8)
        packet[7] = UInt8(sequence & 0xFF)
        packet.replaceSubrange(headerLength..., with: token)
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)
        return Data(packet)
    }

    /// 接受对应 `sequence` 的 echo reply，带不带 IP 头都认。
    ///
    /// datagram ICMP socket 在 Linux 上会剥掉 IP 头，macOS 不保证，猜错会把每台主机
    /// 都静默报成不可达，所以两种封装都试。
    static func matchesReply(_ data: Data, sequence: UInt16) -> Bool {
        let bytes = [UInt8](data)
        if isEchoReply(bytes, sequence: sequence) { return true }
        // IPv4 头至少 20 字节，长度在首字节低 4 位、以 32 位字为单位
        if let first = bytes.first, first >> 4 == 4 {
            let headerLength = Int(first & 0x0F) * 4
            if headerLength >= 20, bytes.count > headerLength {
                return isEchoReply(Array(bytes[headerLength...]), sequence: sequence)
            }
        }
        return false
    }

    private static func isEchoReply(_ bytes: [UInt8], sequence: UInt16) -> Bool {
        guard bytes.count >= headerLength + token.count, bytes[0] == echoReply else { return false }
        let replySequence = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        return replySequence == sequence
            && Array(bytes[headerLength..<(headerLength + token.count)]) == token
    }

    /// 标准 internet checksum：反码求和再取反码。
    static func checksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < data.count {
            sum += UInt32(UInt16(data[index]) << 8 | UInt16(data[index + 1]))
            index += 2
        }
        if index < data.count { sum += UInt32(data[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum & 0xFFFF)
    }

    /// 发一个 echo request 并返回往返**微秒数**。
    ///
    /// 用微秒而不是毫秒：到同网段主机的 overlay 往返远不到 1ms，截成 `0ms` 看起来像
    /// 测坏了而不是很快。
    ///
    /// 返回 nil 表示超时内没有收到匹配回复——主机已关、隧道断开、防火墙吞掉 ICMP
    /// 都会走到这里，区分它们是调用方的职责，这一层只陈述事实。
    static func ping(address: String, sequence: UInt16,
                     timeout: TimeInterval = 2) -> UInt32? {
        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, address, &destination.sin_addr) == 1 else { return nil }
        guard let descriptor = openSocket() else { return nil }
        defer { close(descriptor) }

        var limit = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit,
                   socklen_t(MemoryLayout<timeval>.size))

        let packet = echoRequest(sequence: sequence)
        let started = DispatchTime.now()
        let sent = packet.withUnsafeBytes { buffer in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, buffer.baseAddress, buffer.count, 0,
                           $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else { return nil }

        var buffer = [UInt8](repeating: 0, count: 1500)
        let deadline = started.uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let read = recv(descriptor, &buffer, buffer.count, 0)
            guard read > 0 else { return nil }
            // 序号不符的回复不能吃掉整个预算，所以继续等而不是重置计时
            if matchesReply(Data(buffer.prefix(read)), sequence: sequence) {
                let elapsed = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
                return UInt32(min(elapsed / 1_000, UInt64(UInt32.max)))
            }
        }
        return nil
    }
}
