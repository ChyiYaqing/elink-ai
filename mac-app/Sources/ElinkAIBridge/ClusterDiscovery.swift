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
        let cluster = txt["cluster"].map { String(decoding: $0, as: UTF8.self) }
        let pairable = txt["pairing"].map { String(decoding: $0, as: UTF8.self) == "1" } ?? false
        let peer = DiscoveredClusterPeer(
            nodeID: remoteNode,
            name: sender.name,
            endpoint: "http://\(host):\(sender.port)",
            clusterID: cluster,
            pairable: pairable
        )
        peers[peer.id] = peer
        notify()
    }

    private func notify() {
        let result = peers.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        DispatchQueue.main.async { [weak self] in self?.onPeersChanged?(result) }
    }
}
