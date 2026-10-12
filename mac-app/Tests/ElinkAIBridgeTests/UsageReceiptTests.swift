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
        let renderer = ImageRenderer(content: ReceiptPaper(receipt: receipt, torn: 1))
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

    /// 往右拉从左边撕起、左边先掉（逆时针）；往上推不算撕，拉过头封顶为 1
    func testTearGeometryFollowsThePullDirection() {
        let half = ReceiptView.tearDistance / 2
        XCTAssertEqual(ReceiptView.tearProgress(CGSize(width: 0, height: half)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ReceiptView.tearProgress(CGSize(width: 0, height: -200)), 0)
        XCTAssertEqual(ReceiptView.tearProgress(CGSize(width: 500, height: 500)), 1)

        XCTAssertEqual(ReceiptView.tearTip(progress: 0.25, fromRight: false, width: 300), 75)
        XCTAssertEqual(ReceiptView.tearTip(progress: 0.25, fromRight: true, width: 300), 225)
        XCTAssertLessThan(ReceiptView.tearAngle(progress: 0.5, fromRight: false), 0)
        XCTAssertGreaterThan(ReceiptView.tearAngle(progress: 0.5, fromRight: true), 0)
        XCTAssertEqual(ReceiptView.tearAngle(progress: 0, fromRight: false), 0)
    }

    /// 手撕毛边：同一个种子画出同一条线（纸身与残边才对得上），深浅落在范围内，
    /// 齿距不等——等距等高的锯齿看起来就是机器切的
    func testTornEdgeIsIrregularButReproducible() {
        let line = TornEdge.line(width: 300, seed: 42)
        XCTAssertEqual(line, TornEdge.line(width: 300, seed: 42))
        XCTAssertNotEqual(line, TornEdge.line(width: 300, seed: 43))
        XCTAssertEqual(line.first?.x, 0)
        XCTAssertEqual(line.last?.x, 300)
        XCTAssertTrue(line.allSatisfy { $0.y >= 0 && $0.y <= TornEdge.depth })

        let gaps = zip(line, line.dropFirst()).map { ($1.x - $0.x).rounded(toPlaces: 1) }
        XCTAssertGreaterThan(Set(gaps).count, 10, "齿距应当参差不齐")
        XCTAssertGreaterThan(Set(line.map { $0.y.rounded(toPlaces: 1) }).count, 10, "深浅应当参差不齐")
    }

    /// 撕到一半：撕开的一侧跟撕口走，另一侧仍是直边
    func testPartialTearKeepsTheUntornSideStraight() {
        let line = TornEdge.line(width: 300, seed: 7)
        let half = TornEdge.partial(line, width: 300, torn: 0.5, fromRight: true, untornY: -1)
        XCTAssertTrue(half.filter { $0.x < 149 }.allSatisfy { $0.y == -1 })
        XCTAssertFalse(half.filter { $0.x > 151 }.contains { $0.y == -1 })
        XCTAssertTrue(TornEdge.partial(line, width: 300, torn: 0, fromRight: false, untornY: 3)
                          .allSatisfy { $0.y == 3 })
    }

    private typealias Stage = ReceiptTearStage<DragGesture>

    /// 撕下后落定：先以中心缩放、再绕断角转、再平移，四个角都必须留在出纸区里
    func testRestingPaperStaysInsideThePanel() {
        let paper = CGSize(width: ReceiptPaper.width, height: 560)
        for stage in [CGSize(width: 408, height: 520), CGSize(width: 480, height: 700),
                      CGSize(width: 408, height: 380)] {
            for fromRight in [false, true] {
                let pose = Stage.restPose(stage: stage, paperSize: paper, fromRight: fromRight)
                let origin = CGPoint(x: (stage.width - paper.width) / 2,
                                     y: Stage.cutterY + Stage.stubLength)
                let anchor = CGPoint(x: fromRight ? 0 : paper.width, y: 0)
                let radians = pose.angle * .pi / 180
                for corner in [CGPoint(x: 0, y: 0), CGPoint(x: paper.width, y: 0),
                               CGPoint(x: 0, y: paper.height), CGPoint(x: paper.width, y: paper.height)] {
                    let scaled = CGPoint(x: paper.width / 2 + (corner.x - paper.width / 2) * pose.scale,
                                         y: paper.height / 2 + (corner.y - paper.height / 2) * pose.scale)
                    let dx = scaled.x - anchor.x, dy = scaled.y - anchor.y
                    let x = origin.x + anchor.x + dx * cos(radians) - dy * sin(radians) + pose.offset.width
                    let y = origin.y + anchor.y + dx * sin(radians) + dy * cos(radians) + pose.offset.height
                    XCTAssertGreaterThanOrEqual(x, 0, "\(stage) fromRight=\(fromRight)")
                    XCTAssertLessThanOrEqual(x, stage.width, "\(stage) fromRight=\(fromRight)")
                    XCTAssertGreaterThanOrEqual(y, Stage.cutterY, "\(stage) fromRight=\(fromRight)")
                    XCTAssertLessThanOrEqual(y, stage.height - Stage.restBottomReserve,
                                             "\(stage) fromRight=\(fromRight)")
                }
            }
        }
    }

    /// 捏着纸往面板外拖很远，中心只越界一小截
    func testHeldPaperIsHeldBackAtThePanelEdge() {
        let stage = CGSize(width: 408, height: 520), paper = CGSize(width: 300, height: 480)
        let offset = Stage.heldOffset(CGSize(width: 2000, height: 2000), angle: -14,
                                      stage: stage, paperSize: paper, fromRight: false)
        let center = Stage.paperCenter(stage: stage, paperSize: paper, fromRight: false,
                                       angle: -14, offset: offset)
        XCTAssertLessThanOrEqual(center.x - (stage.width - paper.width / 2), Stage.maxOvershoot + 0.001)
        XCTAssertLessThanOrEqual(center.y - (stage.height - paper.height / 2), Stage.maxOvershoot + 0.001)

        // 面板内的小幅拖动不受影响
        let small = CGSize(width: 10, height: 20)
        XCTAssertEqual(Stage.heldOffset(small, angle: 0, stage: CGSize(width: 408, height: 900),
                                        paperSize: paper, fromRight: false), small)
    }
}

private extension CGFloat {
    func rounded(toPlaces places: Int) -> CGFloat {
        let factor = pow(10, CGFloat(places))
        return (self * factor).rounded() / factor
    }
}
