import Foundation

final class ClusterDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var onPeersChanged: (([DiscoveredClusterPeer]) -> Void)?

    private let browser = NetServiceBrowser()
    private var publisher: NetService?
    private var services: [NetService] = []
    private var peers: [String: DiscoveredClusterPeer] = [:]
    private var nodeID = ""
    private var nodeName = ""
    private var clusterID: String?
    private var pairable = false
    private var port: Int32 = 8765

    func start(nodeID: String, nodeName: String, clusterID: String?,
               pairable: Bool, port: UInt16) {
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.clusterID = clusterID
        self.pairable = pairable
        self.port = Int32(port)
        browser.delegate = self
        browser.searchForServices(ofType: "_elink-ai._tcp.", inDomain: "local.")
        publish()
    }

    func update(nodeName: String, clusterID: String?, pairable: Bool) {
        self.nodeName = nodeName
        self.clusterID = clusterID
        self.pairable = pairable
        publisher?.setTXTRecord(Self.txtData(
            nodeID: nodeID, clusterID: clusterID, pairable: pairable
        ))
    }

    func stop() {
        browser.stop()
        publisher?.stop()
        publisher = nil
        services.removeAll()
        peers.removeAll()
    }

    private func publish() {
        publisher?.stop()
        let service = NetService(
            domain: "local.", type: "_elink-ai._tcp.", name: nodeName, port: port
        )
        service.delegate = self
        service.setTXTRecord(Self.txtData(
            nodeID: nodeID, clusterID: clusterID, pairable: pairable
        ))
        service.publish()
        publisher = service
    }

    private static func txtData(nodeID: String, clusterID: String?, pairable: Bool) -> Data {
        var values: [String: Data] = [
            "version": Data("2".utf8),
            // 配对协议版本单独广播；旧版本没有该字段，解析时按 2 处理
            "pairproto": Data(String(DiscoveredClusterPeer.currentPairingProtocol).utf8),
            "node": Data(nodeID.utf8),
            "pairing": Data(pairable ? "1".utf8 : "0".utf8),
        ]
        if let clusterID { values["cluster"] = Data(clusterID.utf8) }
        return NetService.data(fromTXTRecord: values)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService,
                           moreComing: Bool) {
        guard service !== publisher else { return }
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService,
                           moreComing: Bool) {
        services.removeAll { $0 === service }
        if let key = peers.first(where: { $0.value.name == service.name })?.key {
            peers.removeValue(forKey: key)
            notify()
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              sender.port > 0,
              let data = sender.txtRecordData() else { return }
        let txt = NetService.dictionary(fromTXTRecord: data)
        let remoteNode = txt["node"].map { String(decoding: $0, as: UTF8.self) } ?? ""
        guard remoteNode != nodeID else { return }
        // Same-machine guard: a co-located bridge (e.g. an elink-tui on this
        // host) advertises this machine's own addresses under a different node
        // id. Syncing with it would double-count this machine's usage in the
        // cluster, so skip it. Intentional localhost setups can still use a
        // manual VPN endpoint.
        let peerAddresses = Self.peerAddressStrings(from: sender.addresses ?? [])
        if Self.isColocated(peerAddresses: peerAddresses, localAddresses: Self.localAddresses()) {
            return
        }
        let cluster = txt["cluster"].map { String(decoding: $0, as: UTF8.self) }
        let pairable = txt["pairing"].map { String(decoding: $0, as: UTF8.self) == "1" } ?? false
        let pairingProtocol = txt["pairproto"]
            .flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 2
        let peer = DiscoveredClusterPeer(
            nodeID: remoteNode,
            name: sender.name,
            endpoint: "http://\(host):\(sender.port)",
            clusterID: cluster,
            pairable: pairable,
            pairingProtocol: pairingProtocol
        )
        peers[peer.id] = peer
        notify()
    }

    private func notify() {
        let result = peers.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        DispatchQueue.main.async { [weak self] in self?.onPeersChanged?(result) }
    }

    /// True when a resolved peer advertises a loopback or this machine's own
    /// address, meaning it is really a co-located bridge, not a remote node.
    static func isColocated(peerAddresses: [String], localAddresses: Set<String>) -> Bool {
        peerAddresses.contains { isLoopbackAddress($0) || localAddresses.contains($0) }
    }

    static func isLoopbackAddress(_ ip: String) -> Bool {
        ip == "::1" || ip.hasPrefix("127.")
    }

    /// Drops an IPv6 zone id (e.g. `fe80::1%en0` → `fe80::1`) and lowercases so
    /// this machine's addresses and a peer's advertised ones compare equal.
    static func normalizeIP(_ value: String) -> String {
        let base = value.split(separator: "%", maxSplits: 1).first.map(String.init) ?? value
        return base.lowercased()
    }

    /// This machine's interface addresses (IPv4 and IPv6, including loopback).
    private static func localAddresses() -> Set<String> {
        var result: Set<String> = []
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return result }
        defer { freeifaddrs(addresses) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = pointer.pointee
            guard let address = item.ifa_addr else { continue }
            let family = address.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.insert(normalizeIP(String(cString: host)))
        }
        return result
    }

    /// Parses a `NetService`'s resolved socket addresses into numeric IP
    /// strings for comparison against this machine's addresses.
    private static func peerAddressStrings(from addresses: [Data]) -> [String] {
        addresses.compactMap { datum -> String? in
            datum.withUnsafeBytes { raw -> String? in
                guard raw.count >= MemoryLayout<sockaddr>.size,
                      let base = raw.baseAddress else { return nil }
                let sockaddrPointer = base.assumingMemoryBound(to: sockaddr.self)
                let family = sockaddrPointer.pointee.sa_family
                guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { return nil }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(sockaddrPointer, socklen_t(datum.count), &host,
                                  socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return normalizeIP(String(cString: host))
            }
        }
    }
}
