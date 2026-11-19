import Foundation
import Testing
@testable import HowManyUsage

struct CacheUsageTests {
    @Test func providerInputAccountingKeepsTheirDifferentSemantics() throws {
        let codex = try #require(CodexSpeed.CacheUsage.codex([
            "input_tokens": 1000, "cached_input_tokens": 800]))
        #expect(codex == .init(read: 800, input: 1000))
        let claude = try #require(CodexSpeed.CacheUsage.claude([
            "input_tokens": 100, "cache_creation_input_tokens": 100, "cache_read_input_tokens": 800]))
        #expect(claude == .init(read: 800, input: 1000))
        let dsh = try #require(CodexSpeed.CacheUsage.dsh([
            "inputTokens": 200, "cacheReadTokens": 800, "outputTokens": 50, "totalTokens": 1050]))
        #expect(dsh == .init(read: 800, input: 1000))
        let antigravity = try #require(CodexSpeed.CacheUsage.antigravity([
            "input_tokens": 150, "cache_write_tokens": 50, "cache_read_tokens": 800]))
        #expect(antigravity == .init(read: 800, input: 1000))
    }

    @Test func missingOrInconsistentFieldsRemainUnknown() {
        #expect(CodexSpeed.CacheUsage.codex(["input_tokens": 100]) == nil)
        #expect(CodexSpeed.CacheUsage.codex(["input_tokens": 100, "cached_input_tokens": 101]) == nil)
        #expect(CodexSpeed.CacheUsage.codex(["input_tokens": 0, "cached_input_tokens": 0]) == nil)
        #expect(CodexSpeed.CacheUsage.claude(["input_tokens": 10, "cache_read_input_tokens": 1]) == nil)
        #expect(CodexSpeed.CacheUsage.claude(["input_tokens": Int.max, "cache_creation_input_tokens": 1,
                                             "cache_read_input_tokens": 1]) == nil)
        #expect(CodexSpeed.CacheUsage.dsh(["inputTokens": 100, "cacheReadTokens": 900,
                                          "outputTokens": 20, "totalTokens": 500]) == nil)
        #expect(CodexSpeed.CacheUsage.dsh(["inputTokens": 100, "outputTokens": 20,
                                          "totalTokens": 120]) == nil)
    }

    @Test func cacheRateWeightsTokensAndExcludesOldOrMissingSamples() throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let samples = [
            CodexSpeed.Sample(responseID: "a", model: "gpt-6-sol", effort: "", outputTokens: 10,
                              seconds: 2, completedAt: now, outputSeconds: 1,
                              cacheUsage: .init(read: 90, input: 100)),
            CodexSpeed.Sample(responseID: "b", model: "gpt-6-sol", effort: "", outputTokens: 10,
                              seconds: 2, completedAt: now, outputSeconds: 1,
                              cacheUsage: .init(read: 0, input: 900)),
            CodexSpeed.Sample(responseID: "old", model: "gpt-6-sol", effort: "", outputTokens: 10,
                              seconds: 2, completedAt: now.addingTimeInterval(-14_401), outputSeconds: 1,
                              cacheUsage: .init(read: 1000, input: 1000)),
            CodexSpeed.Sample(responseID: "unknown", model: "gpt-6-sol", effort: "", outputTokens: 10,
                              seconds: 2, completedAt: now, outputSeconds: 1)
        ]
        let snapshot = CodexSpeed.Snapshot(samples: samples, now: now)
        let row = try #require(snapshot.rows.first)
        #expect(row.cachePercent == 9)
        #expect(row.text.hasSuffix("9%"))
        #expect(snapshot.lines[1].contains("Cache"))
    }
}
