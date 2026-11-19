import Foundation
import Testing
@testable import HowManyUsage

struct ClaudeSpeedTests {
    @Test func transcriptEstimatesUseMatchingPromptAndDeduplicateMessages() throws {
        let now = Date(timeIntervalSince1970: 100_100)
        func timestamp(_ offset: TimeInterval) -> String {
            ISO8601DateFormatter().string(from: now.addingTimeInterval(offset))
        }
        let records: [[String: Any]] = [
            ["type": "assistant", "timestamp": timestamp(-80), "message": ["id": "no-prompt", "model": "claude-opus-5-5", "usage": ["output_tokens": 100]]],
            ["type": "user", "timestamp": timestamp(-60)],
            ["type": "assistant", "timestamp": timestamp(-55), "message": ["id": "reply", "model": "claude-opus-5-5", "usage": ["output_tokens": 20]]],
            ["type": "assistant", "timestamp": timestamp(-50), "message": ["id": "reply", "model": "claude-opus-5-5", "usage": ["output_tokens": 100, "input_tokens": 100, "cache_creation_input_tokens": 100, "cache_read_input_tokens": 800]]],
            ["type": "user", "timestamp": timestamp(-40), "isSidechain": true],
            ["type": "assistant", "timestamp": timestamp(-39), "isSidechain": true, "message": ["id": "side", "model": "claude-haiku-5-5", "usage": ["output_tokens": 100]]],
            ["type": "user", "timestamp": timestamp(-20)],
            ["type": "assistant", "timestamp": timestamp(-16), "message": ["id": "reply2", "model": "claude-sonnet-5-5", "usage": ["output_tokens": 80]]],
            ["type": "assistant", "timestamp": timestamp(-15), "message": ["id": "zero", "model": "claude-sonnet-5-5", "usage": ["output_tokens": 0]]]
        ]
        let lines = try records.map { try JSONSerialization.data(withJSONObject: $0) }
        var data = Data()
        for line in lines { data.append(line); data.append(10) }
        let samples = ClaudeModelScanner.samples(in: data, now: now)
        #expect(samples.count == 2)
        let opus = try #require(samples.first { $0.model == "claude-opus-5-5" })
        #expect(opus.outputTokens == 100)
        #expect(opus.seconds == 10)
        #expect(opus.includesWait)
        #expect(opus.cacheUsage == .init(read: 800, input: 1000))
        #expect(opus.waitSeconds == nil && opus.outputSeconds == nil)
        let snapshot = CodexSpeed.Snapshot(samples: samples, now: now)
        let row = try #require(snapshot.rows.first { $0.name == "claude-opus-5-5" })
        #expect(row.tps == 10 && row.ttft == nil)
        #expect(row.text.contains("10 tok/s"))
        #expect(ClaudeModelScanner.samples(in: data, now: now.addingTimeInterval(14_401)).isEmpty)
    }

    @Test func pureOutputSamplesTakePrecedenceOverTranscriptFallback() throws {
        let now = Date()
        let samples = [
            CodexSpeed.Sample(responseID: "stream", model: "claude-opus", effort: "", outputTokens: 1000,
                seconds: 2, completedAt: now, outputSeconds: 1),
            CodexSpeed.Sample(responseID: "transcript", model: "claude-opus", effort: "", outputTokens: 100,
                seconds: 8, completedAt: now, includesWait: true)
        ]
        let row = try #require(CodexSpeed.Snapshot(samples: samples, now: now).rows.first)
        #expect(row.tps == 1000)
        #expect(row.outputCount == 1)
        #expect(!row.includesWait)
    }

    @Test func rejectsStaleAndInvalidSamples() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        func row(_ id: String, _ seconds: Double, _ age: Double) -> [String: Any] {
            ["id": id, "model": "claude-opus-test", "tokens": 100,
             "seconds": seconds, "timestamp": now.timeIntervalSince1970 - age]
        }
        let data = try JSONSerialization.data(withJSONObject: ["samples": [
            row("valid", 1, 10), row("short", 0.1, 10), row("stale", 1, 15000), row("future", 1, -1)]])
        try data.write(to: root.appendingPathComponent("session.json"))
        let samples = ClaudeSpeed.samples(root: root, now: now)
        #expect(samples.map(\.responseID) == ["valid"])
        #expect(samples.first?.waitSeconds == nil)
        #expect(samples.first?.rate == 100)
    }

    @Test func newWindowCanProjectFromRecentDailyData() {
        let snapshot = CodexServerUsage.Snapshot(fetchedAt: Date(), days: [
            .init(date: "2026-10-21", local: .zero, cloud: .zero, other: .zero)])
        let start = ISO8601DateFormatter().date(from: "2026-10-22T00:00:00Z")!
        #expect(snapshot.valuationNote(windowStart: start).contains("projected"))
        #expect(snapshot.cloudUSD(windowStart: start, using: CodexValue.cloudPricing, now: start.addingTimeInterval(3600)) == 0)
    }
}
