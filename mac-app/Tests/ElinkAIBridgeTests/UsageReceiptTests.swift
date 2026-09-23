import SwiftUI
import XCTest
@testable import ElinkAIBridge

final class UsageReceiptTests: XCTestCase {
    private let table = [
        "gpt-a": ModelPricing(input: 1, output: 10, cacheRead: 0.1, cacheWrite: 0),
        "claude-b": ModelPricing(input: 2, output: 20, cacheRead: 0.2, cacheWrite: 2.5),
    ]

    func testReceiptSumsCostsAndCategoriesAcrossProviders() {
        let now = Date()
        let today = StatusService.dayKey(now)
        let receipt = UsageReceipt.make(
            range: .day, now: now,
            usage: [
                "codex": [DailyModelUsage(day: today, provider: "codex", model: "gpt-a", tokens: 3_000_000)],
                "claude": [DailyModelUsage(day: today, provider: "claude", model: "claude-b", tokens: 1_000_000)],
            ],
            modelCategories: [
                "codex": [
                    ModelCategoryUsage(day: today, provider: "codex", model: "gpt-a", category: "input", tokens: 1_000_000),
                    ModelCategoryUsage(day: today, provider: "codex", model: "gpt-a", category: "cache_read", tokens: 1_900_000),
                    ModelCategoryUsage(day: today, provider: "codex", model: "gpt-a", category: "output", tokens: 100_000),
                ],
                "claude": [
                    ModelCategoryUsage(day: today, provider: "claude", model: "claude-b", category: "output", tokens: 1_000_000),
                ],
            ],
            sessions: 4, table: table)

        XCTAssertEqual(receipt.clients.map(\.name), ["Claude Code", "Codex CLI"])
        // codex: 1×1 + 1.9×0.1 + 0.1×10 = 2.19；claude: 1×20 = 20
        XCTAssertEqual(receipt.clients[1].cost, 2.19, accuracy: 1e-9)
        XCTAssertEqual(receipt.totalCost, 22.19, accuracy: 1e-9)
        XCTAssertEqual(receipt.totalTokens, 4_000_000)
        XCTAssertEqual(receipt.input, 2_900_000)
        XCTAssertEqual(receipt.output, 1_100_000)
        XCTAssertEqual(try XCTUnwrap(receipt.cacheHitRate), 1_900_000.0 / 2_900_000, accuracy: 1e-9)
        XCTAssertEqual(receipt.coverage, 1)
        XCTAssertEqual(receipt.sessions, 4)
    }

    /// 窗口外的行不计入；没有定价的模型照列 token、费用为 nil，并单独点名。
    func testReceiptFiltersByRangeAndNamesUnpricedModels() {
        let now = Date()
        let today = StatusService.dayKey(now)
        let old = StatusService.dayKey(now.addingTimeInterval(-10 * 86_400))
        let receipt = UsageReceipt.make(
            range: .week, now: now,
            usage: ["codex": [
                DailyModelUsage(day: today, provider: "codex", model: "mystery", tokens: 500),
                DailyModelUsage(day: old, provider: "codex", model: "gpt-a", tokens: 9_999),
            ]],
            modelCategories: ["codex": [
                ModelCategoryUsage(day: old, provider: "codex", model: "gpt-a", category: "input", tokens: 9_999),
            ]],
            sessions: nil, table: table)

        XCTAssertEqual(receipt.clients.count, 1)
        XCTAssertEqual(receipt.clients[0].lines, [UsageReceipt.Line(model: "mystery", tokens: 500, cost: nil)])
        XCTAssertEqual(receipt.unpriced, ["mystery"])
        XCTAssertEqual(receipt.totalCost, 0)
        // 窗口内的 500 token 没有分类明细
        XCTAssertEqual(receipt.coverage, 0)
        XCTAssertNil(receipt.cacheHitRate)
    }

    func testWindowStartMatchesStatsRanges() {
        let calendar = StatusService.aggregationCalendar
        let now = Date()
        let today = calendar.startOfDay(for: now)
        XCTAssertEqual(UsageReceipt.windowStart(range: .day, now: now), today)
        XCTAssertEqual(StatusService.dayKey(UsageReceipt.windowStart(range: .week, now: now)),
                       UsageStats.buckets(rows: [], range: .week, now: now).first?.id)
        XCTAssertEqual(StatusService.dayKey(UsageReceipt.windowStart(range: .month, now: now)),
                       UsageStats.buckets(rows: [], range: .month, now: now).first?.id)
        let yearStart = UsageReceipt.windowStart(range: .year, now: now)
        XCTAssertEqual(calendar.component(.day, from: yearStart), 1)
        XCTAssertEqual(String(StatusService.dayKey(yearStart).prefix(7)),
                       UsageStats.buckets(rows: [], range: .year, now: now).first?.id)
    }

    func testSessionCountSkipsOldFilesAndSubagents() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elink-receipt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let claude = base.appendingPathComponent("claude/projects")
        let codex = base.appendingPathComponent("codex/sessions")
        let since = Date().addingTimeInterval(-3600)
        func write(_ url: URL, _ text: String, age: TimeInterval = 0) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)],
                                                  ofItemAtPath: url.path)
        }
        try write(claude.appendingPathComponent("-Users-me-app/a.jsonl"), "{}")
        try write(claude.appendingPathComponent("-Users-me-app/old.jsonl"), "{}", age: 7200)
        try write(claude.appendingPathComponent("-Users-me-app/a/subagents/agent-1.jsonl"), "{}")
        try write(claude.appendingPathComponent("-Users-me-app--claude-worktrees-agent-x/w.jsonl"), "{}")
        try write(codex.appendingPathComponent("2026/09/23/rollout-root.jsonl"),
                  #"{"payload":{"id":"root","parent_thread_id":null}}"# + "\n{}")
        try write(codex.appendingPathComponent("2026/09/23/rollout-kid.jsonl"),
                  #"{"payload":{"id":"kid","parent_thread_id":"root"}}"# + "\n{}")

        XCTAssertEqual(UsageReceipt.sessionCount(since: since, claudeRoot: claude, codexRoot: codex), 2)
    }

    /// 超长模型名只截断，不把小票撑宽——撕下来的 PNG 宽度必须固定。
    @MainActor
    func testPaperKeepsItsWidthWithLongModelNames() throws {
        let today = StatusService.dayKey(Date())
        let receipt = UsageReceipt.make(
            range: .day,
            usage: ["claude": [DailyModelUsage(day: today, provider: "claude",
                                               model: String(repeating: "very-long-model-", count: 8),
                                               tokens: 1_000)]],
            modelCategories: [:], sessions: 1, table: table)
        let renderer = ImageRenderer(content: ReceiptPaper(receipt: receipt, tornTop: true))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertEqual(image.size.width, ReceiptPaper.width)
        XCTAssertGreaterThan(image.size.height, 300)
    }

    func testPeriodTextSpansTheRange() {
        UserDefaults.standard.set(AppLanguage.chinese.rawValue, forKey: AppLanguage.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: AppLanguage.defaultsKey) }
        let calendar = StatusService.aggregationCalendar
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 10))!
        let week = UsageReceipt.make(range: .week, now: now, usage: [:], modelCategories: [:],
                                     sessions: 0, table: table)
        XCTAssertEqual(ReceiptPaper.periodText(week), "9月17日 – 9月23日")
        let year = UsageReceipt.make(range: .year, now: now, usage: [:], modelCategories: [:],
                                     sessions: 0, table: table)
        XCTAssertEqual(ReceiptPaper.periodText(year), "2025年10月 – 2026年9月")
    }
}
