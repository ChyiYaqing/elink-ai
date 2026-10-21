import Foundation

struct UsageWindow: Codable, Equatable {
    var percent: Double?
    var resetMinutes: Int?
    var resetAt: Date?

    func discardingIfExpired(at now: Date = Date()) -> UsageWindow {
        guard let resetAt else { return self }
        var value = self
        if resetAt <= now {
            value.percent = nil
            value.resetMinutes = nil
        } else {
            value.resetMinutes = Int(resetAt.timeIntervalSince(now) / 60)
        }
        return value
    }
}

/// 订阅额度之外、按量计费的那个池子（Claude 的 `extra_usage`、Codex 的
/// spend control 额度）。
///
/// Claude 给的是最小货币单位，`decimal_places` 说明要缩几位：`monthly_limit:
/// 10000` 配 `decimal_places: 2` 是 $100，直接显示原值会把上限夸大一百倍。
/// 这里存的是换算好的数，显示端不再做任何缩放。
///
/// `unit` 要么是 ISO 货币代码，要么是 `credits`——Codex 的额度按积分计，给它
/// 加个 `$` 就是把积分说成了美元。两种都可能出现，所以单位必须跟着数走。
struct ExtraUsage: Codable, Equatable {
    static let creditsUnit = "credits"

    var used: Double
    var limit: Double
    var percent: Double
    var unit: String
}

/// 只对某个模型生效的周额度，例如 Max 账号单独计的 Opus 周限额。
///
/// 与 `weekly` 分开：那是整个账号的总周限额，这些是套在它里面的子限额。合并成
/// 一条会让「总量还很宽裕但 Opus 已经打满」这种真实状态无法表达。
struct ScopedLimit: Codable, Equatable {
    var id: String
    var title: String
    var window: UsageWindow

    func discardingIfExpired(at now: Date = Date()) -> ScopedLimit {
        var value = self
        value.window = window.discardingIfExpired(at: now)
        return value
    }
}

struct ProviderUsage: Codable, Equatable {
    var primary = UsageWindow()
    var weekly = UsageWindow()
    var scopedLimits: [ScopedLimit] = []
    var extraUsage: ExtraUsage?
    /// 账号上还剩多少积分（Codex 的 `credits.balance`）。只有接口说这个账号
    /// 真的有积分池时才是非 nil——给每个 Plus 用户挂一行「余额 0」是噪声。
    var creditBalance: Double?
    var error: String?
    var fetchedAt: Date?
    var isCached = false
}

struct ModelUsage: Codable, Equatable {
    var model: String
    var tokens: Int
}

struct BridgeSessionSummary: Codable, Equatable {
    var id: String
    var provider: String
    var project: String
    var model: String
    var state: String
    var updatedAt: Date
}

struct BridgeRecentEvent: Codable, Equatable {
    var id: String
    var provider: String
    var kind: String
    var occurredAt: Date
}

struct AgentStatus: Codable, Equatable {
    var state = "offline"
    var tokensToday = 0
    var modelUsageToday: [ModelUsage] = []
    var primary = UsageWindow()
    var weekly = UsageWindow()
    var scopedLimits: [ScopedLimit] = []
    var extraUsage: ExtraUsage?
    var creditBalance: Double?
    /// 今日用量的 API 等价成本，nil 表示连一条分类明细都没有。
    /// 这不是账单：订阅额度内不按 token 收费，读者必须照这个口径措辞。
    var costToday: Double?
    /// 没有定价、因而没计入 `costToday` 的模型。不显示出来，一个偏低的总额
    /// 看不出偏低。
    var unpricedModels: [String] = []
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
    var currentSessions: [BridgeSessionSummary] = []
    var recentEvents: [BridgeRecentEvent] = []

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
            // 额外用量和模型作用域周限额是后加的：老读者读不到这两个键，行为与
            // 从前一致，不需要提 schema_version。
            result["scoped_limits"] = value.scopedLimits.map {
                [
                    "id": $0.id,
                    "title": $0.title,
                    "pct": nullable($0.window.percent),
                    "reset_min": nullable($0.window.resetMinutes),
                ] as [String: Any]
            }
            result["cost_today"] = nullable(value.costToday)
            result["unpriced_models"] = value.unpricedModels
            result["extra_usage"] = value.extraUsage.map {
                [
                    "used": $0.used,
                    "limit": $0.limit,
                    "pct": $0.percent,
                    "unit": $0.unit,
                ] as [String: Any]
            } ?? NSNull()
            result["credit_balance"] = nullable(value.creditBalance)
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
            "current_sessions": currentSessions.prefix(3).map {
                [
                    "id": $0.id,
                    "provider": $0.provider,
                    "project": $0.project,
                    "model": $0.model,
                    "state": $0.state,
                    "updated_at": Int($0.updatedAt.timeIntervalSince1970),
                ] as [String: Any]
            },
            "recent_events": recentEvents.prefix(3).map {
                [
                    "id": $0.id,
                    "provider": $0.provider,
                    "kind": $0.kind,
                    "occurred_at": Int($0.occurredAt.timeIntervalSince1970),
                ] as [String: Any]
            },
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
    /// 屏幕此刻在显示哪一类内容：`ai` 是用量面板，`monitor` 是设备监控页。
    /// 它和 `mode` 是两回事——`mode` 只决定用量面板怎么排版，监控页是空闲填充页。
    let content: String
    let monitorEnabled: Bool
    let monitorIdleAfter: Int?

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
        content = json["content"] as? String ?? "ai"
        let monitor = json["monitor"] as? [String: Any] ?? [:]
        monitorEnabled = monitor["enabled"] as? Bool ?? false
        monitorIdleAfter = (monitor["idle_after_s"] as? NSNumber)?.intValue
    }

    /// 屏幕正停在设备监控页上。
    var showsMonitor: Bool { content == "monitor" }
}

enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(value) = self { return value }
        return tr("未知错误", "Unknown error")
    }
}
