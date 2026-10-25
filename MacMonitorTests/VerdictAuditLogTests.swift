import Foundation
import Testing
@testable import MacMonitor

struct VerdictAuditLogTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ time: Date, name: String = "g", tokens: Int = 700, error: String? = nil, result: String = "종료 추천", body: String = "x") -> VerdictAuditEntry {
        VerdictAuditEntry(
            time: time, engineID: "jev", model: "jev-1.14.0", groupID: name, groupName: name, mode: .full,
            requestBody: body, responseBody: "{}", httpStatus: error == nil ? 200 : 500, latencyMs: 190,
            inputTokens: tokens, outputTokens: 60, result: result, confidence: 0.9, error: error
        )
    }

    private func log(_ dir: URL = tempDirectory(), clock: TestClock? = nil, maxBytes: Int = VerdictAuditLog.maxBytes) -> VerdictAuditLog {
        let c = clock ?? TestClock(t0)
        return VerdictAuditLog(directory: dir, maxBytes: maxBytes, now: { c.now })
    }

    @Test func writesAndReadsNewestFirst() async {
        let l = log()
        await l.append(entry(t0, name: "a"))
        await l.append(entry(t0 + 10, name: "b"))
        await l.append(entry(t0 + 20, name: "c"))
        #expect(await l.recent(limit: 2).map(\.groupName) == ["c", "b"])
        let lines = (try? String(contentsOf: l.fileURL, encoding: .utf8))?.split(separator: "\n").count
        #expect(lines == 3)
    }

    @Test func failuresOnlyFilter() async {
        let l = log()
        await l.append(entry(t0, name: "ok"))
        await l.append(entry(t0 + 1, name: "bad", error: "HTTP 500"))
        #expect(await l.recent(limit: 10, failuresOnly: true).map(\.groupName) == ["bad"])
    }

    @Test func monthSummaryCostAndFailures() async {
        let l = log()
        let cal = Calendar(identifier: .gregorian)
        await l.append(entry(t0, tokens: 1_000_000))
        await l.append(entry(t0 + 5, tokens: 500_000, error: "x"))
        await l.append(entry(t0 + 6, tokens: 0, result: VerdictAuditEntry.skippedRateLimit))
        await l.append(entry(t0 - 90 * 86_400, tokens: 999)) // 다른 달 (보관 정리는 append 때 이미 지나감)
        let s = await l.monthSummary(at: t0, calendar: cal)
        #expect(s.calls == 2 && s.failures == 1 && s.inputTokens == 1_500_000)
        #expect(abs(s.estimatedCostUSD - 0.063) < 1e-9)
    }

    @Test func clearDeletesFile() async {
        let l = log()
        await l.append(entry(t0))
        await l.clear()
        #expect(!FileManager.default.fileExists(atPath: l.fileURL.path))
        #expect(await l.recent(limit: 5).isEmpty)
    }

    @Test func prunesEntriesOlderThanThirtyDays() async {
        let clock = TestClock(t0)
        let l = log(clock: clock)
        await l.append(entry(t0 - 31 * 86_400, name: "old"))
        await l.append(entry(t0 - 29 * 86_400, name: "recent"))
        await l.prune()
        #expect(await l.recent(limit: 10).map(\.groupName) == ["recent"])
    }

    @Test func prunesOldestLinesOverSizeLimit() async {
        let l = log(maxBytes: 5_000)
        for i in 0..<20 { await l.append(entry(t0 + Double(i), name: "n\(i)", body: String(repeating: "x", count: 500))) }
        await l.prune()
        let size = (try? FileManager.default.attributesOfItem(atPath: l.fileURL.path)[.size] as? Int) ?? 0
        #expect(size <= 5_000 && size > 0)
        let names = await l.recent(limit: 100).map(\.groupName)
        #expect(names.first == "n19" && !names.contains("n0"))
    }

    @Test func dailyPruneRunsOncePerDay() async {
        let clock = TestClock(t0)
        let l = log(clock: clock)
        await l.pruneIfDue() // 첫 호출은 정리
        await l.append(entry(t0 - 40 * 86_400, name: "old"))
        await l.pruneIfDue() // 같은 날 → 건너뜀
        #expect(await l.recent(limit: 10).count == 1)
        clock.advance(86_401)
        await l.pruneIfDue()
        #expect(await l.recent(limit: 10).isEmpty)
    }

    @Test func entryHasNoKeyFields() throws {
        let data = try JSONEncoder().encode(entry(t0))
        let text = String(decoding: data, as: UTF8.self).lowercased()
        #expect(!text.contains("authorization") && !text.contains("apikey") && !text.contains("bearer"))
    }
}

struct MemoryKeyStoreTests {
    @Test func saveReadDelete() throws {
        let store = MemoryKeyStore()
        #expect(store.key(for: "jev") == nil)
        try store.save("k", for: "jev")
        #expect(store.key(for: "jev") == "k")
        try store.delete(for: "jev")
        #expect(store.key(for: "jev") == nil)
    }
}
