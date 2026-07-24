import Foundation

struct UsageWindow: Codable, Equatable {
    var percent: Double?
    var resetMinutes: Int?
    var resetAt: Date?

    func discardingIfExpired(at now: Date = Date()) -> UsageWindow {
        guard let resetAt, resetAt <= now else { return self }
        var value = self
        value.percent = nil
        value.resetMinutes = nil
        return value
    }
}

struct ProviderUsage: Codable, Equatable {
    var primary = UsageWindow()
    var weekly = UsageWindow()
    var error: String?
    var fetchedAt: Date?
    var isCached = false
}

struct ModelUsage: Codable, Equatable {
    var model: String
    var tokens: Int
}

struct AgentStatus: Codable, Equatable {
    var state = "offline"
    var tokensToday = 0
    var modelUsageToday: [ModelUsage] = []
    var primary = UsageWindow()
    var weekly = UsageWindow()
    var needsInput = false
    var error: String?
    var usageFetchedAt: Date?
    var usageCached = false
}

struct ClusterSummary: Codable, Equatable {
    var enabled = false
    var nodeCount = 1
    var onlineCount = 1
    var lastSyncedAt: Date?
}

struct BridgeSnapshot: Codable {
    var claude = AgentStatus()
    var codex = AgentStatus()
    var generatedAt = Date()
    var usageFetchedAt: Date?
    var cluster = ClusterSummary()

    func jsonData() -> Data {
        func nullable(_ value: Any?) -> Any { value ?? NSNull() }
        func provider(_ value: AgentStatus, claude: Bool) -> [String: Any] {
            var result: [String: Any] = [
                "status": value.state,
                "tokens_today": value.tokensToday,
                "model_usage_today": value.modelUsageToday.map {
                    ["model": $0.model, "tokens": $0.tokens]
                },
                "needs_input": value.needsInput,
                "error": nullable(value.error),
                "provider_usage_fetched_at": nullable(value.usageFetchedAt.map {
                    Int($0.timeIntervalSince1970)
                }),
                "provider_usage_cached": value.usageCached,
            ]
            let primary = claude ? "five_hour" : "primary"
            let weekly = claude ? "seven_day" : "weekly"
            result["\(primary)_pct"] = nullable(value.primary.percent)
            result["\(primary)_reset_min"] = nullable(value.primary.resetMinutes)
            result["\(weekly)_pct"] = nullable(value.weekly.percent)
            result["\(weekly)_reset_min"] = nullable(value.weekly.resetMinutes)
            return result
        }
        let object: [String: Any] = [
            "schema_version": 1,
            "generated_at": Int(generatedAt.timeIntervalSince1970),
            "usage_fetched_at": nullable(usageFetchedAt.map { Int($0.timeIntervalSince1970) }),
            "cluster": [
                "enabled": cluster.enabled,
                "node_count": cluster.nodeCount,
                "online_count": cluster.onlineCount,
                "last_synced_at": nullable(cluster.lastSyncedAt.map { Int($0.timeIntervalSince1970) }),
            ],
            "claude": provider(claude, claude: true),
            "codex": provider(codex, claude: false),
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}

struct DeviceInfo {
    let deviceType: String
    let version: String?
    let bridgeURL: String
    let mode: String
    let stale: Bool
    let lastFetchAge: Int?
    let lastRefreshAge: Int?
    let refreshKind: String
    let error: String?

    init(json: [String: Any]) throws {
        guard json["device_type"] as? String == "elink-agent" else {
            throw BridgeError.message(tr("目标不是 elink-agent", "Target is not an elink-agent"))
        }
        deviceType = "elink-agent"
        version = (json["version"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        bridgeURL = json["bridge_url"] as? String ?? ""
        mode = json["mode"] as? String ?? "dashboard"
        stale = json["stale"] as? Bool ?? true
        lastFetchAge = (json["last_fetch_age_s"] as? NSNumber)?.intValue
        lastRefreshAge = (json["last_refresh_age_s"] as? NSNumber)?.intValue
        refreshKind = json["last_refresh_kind"] as? String ?? "none"
        error = json["error"] as? String
    }
}

enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(value) = self { return value }
        return tr("未知错误", "Unknown error")
    }
}
