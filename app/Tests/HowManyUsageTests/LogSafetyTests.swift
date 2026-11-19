import Foundation
import Testing
@testable import HowManyUsage

struct LogSafetyTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func jsonNumbersDoNotTruncateWrapOrTreatBooleansAsCounts() throws {
        let row = try #require(JSONSerialization.jsonObject(with: Data(
            #"{"max":9223372036854775807,"overflow":18446744073709551615,"fraction":1.5,"bool":true,"negative":-10,"huge":1e300}"#.utf8
        )) as? [String: Any])
        #expect(UsageNumbers.count(row["max"]) == Int.max)
        for key in ["overflow", "fraction", "bool", "negative", "huge"] {
            #expect(UsageNumbers.count(row[key]) == 0)
        }
        #expect(UsageNumbers.integer("300") == 300)
        #expect(UsageNumbers.finite("NaN") == nil)
        #expect(UsageNumbers.finite("Infinity") == nil)
        #expect(UsageNumbers.finite(true) == nil)
        #expect(UsageNumbers.finite("42.5") == 42.5)
        #expect(UsageNumbers.sum(Int.max, 1) == Int.max)
        #expect(UsageNumbers.sum(10, Int.min, 20) == 30)
    }

    @Test func invalidUTF8AndPartialTailDoNotDiscardValidRecords() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("active.jsonl")
        var data = Data("{\"id\":1}\n".utf8)
        // Invalid byte inside a JSON string must not be silently repaired.
        data.append(Data("{\"bad\":\"".utf8)); data.append(0xff); data.append(Data("\"}\n".utf8))
        data.append(Data("[]\nnull\n{\"id\":2}\n{\"id\":3,\"text\":\"".utf8))
        data.append(contentsOf: [0xe4, 0xb8]) // split UTF-8 scalar in the active tail
        try data.write(to: file)
        func ids() -> [Int] {
            var ids: [Int] = []
            LocalJSONL.read(file) { _, row in if let id = row["id"] as? Int { ids.append(id) } }
            return ids
        }
        #expect(ids() == [1, 2])
        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data([0xad, 0x22, 0x7d, 10]))
        try writer.close()
        #expect(ids() == [1, 2, 3])
        #expect(try Data(contentsOf: file).prefix(data.count) == data)
    }

    @Test func readExtentIsFixedAndRotationOrTruncationIsSafe() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("active.jsonl")
        try Data("{\"id\":1}\n".utf8).write(to: file)
        var ids: [Int] = []
        LocalJSONL.read(file) { _, row in
            ids.append(row["id"] as? Int ?? -1)
            // The reader must stop at the original EOF, even if a producer appends.
            let writer = try? FileHandle(forWritingTo: file)
            _ = try? writer?.seekToEnd()
            try? writer?.write(contentsOf: Data("{\"id\":2}\n".utf8))
            try? writer?.close()
        }
        #expect(ids == [1])
        try Data("{\"id\":4}".utf8).write(to: file, options: .atomic)
        ids = []
        LocalJSONL.read(file) { _, row in ids.append(row["id"] as? Int ?? -1) }
        #expect(ids == [4])
        let writer = try FileHandle(forWritingTo: file)
        try writer.truncate(atOffset: 0)
        try writer.close()
        ids = []
        #expect(LocalJSONL.read(file) { _, row in ids.append(row["id"] as? Int ?? -1) })
        #expect(ids.isEmpty)
        #expect(!LocalJSONL.read(root.appendingPathComponent("missing")) { _, _ in })
    }

    @Test func oversizedLineDoesNotGrowWithoutBoundOrPoisonNextRecord() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.jsonl")
        var data = Data(repeating: 120, count: LocalJSONL.maximumLineBytes + 1)
        data.append(Data("\n{\"id\":9}\n".utf8))
        try data.write(to: file)
        var ids: [Int] = []
        #expect(LocalJSONL.read(file) { _, row in ids.append(row["id"] as? Int ?? -1) })
        #expect(ids == [9])
    }

    @Test func speedAggregationAvoidsIntegerOverflowAndInvalidTiming() throws {
        let now = Date()
        let sample = CodexSpeed.Sample(responseID: "one", model: "gpt-6-sol", effort: "high",
            outputTokens: Int.max, seconds: 2, completedAt: now, outputSeconds: 2)
        let bad = CodexSpeed.Sample(responseID: "bad", model: "gpt-6-sol", effort: "high",
            outputTokens: Int.max, seconds: .infinity, completedAt: now, outputSeconds: .infinity)
        let zero = CodexSpeed.Sample(responseID: "zero", model: "gpt-6-sol", effort: "high",
            outputTokens: Int.max, seconds: 0, completedAt: now, outputSeconds: 0)
        #expect(bad.rate == nil)
        #expect(zero.rate == nil)
        let snapshot = CodexSpeed.Snapshot(samples: [sample, sample, bad, zero], now: now)
        let row = try #require(snapshot.rows.first)
        #expect(row.outputCount == 2)
        #expect(row.tps == Double(Int.max) / 2)
        #expect(row.tps?.isFinite == true)
    }

    @Test func historySurvivesHugeCountsAndAnInvalidActiveTail() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".gemini/antigravity/brain/fixture/.system_generated/logs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let row: [String: Any] = ["type": "PLANNER_RESPONSE", "created_at": timestamp,
            "input_tokens": Int.max, "output_tokens": Int.max, "cache_read_tokens": Int.max]
        var data = try JSONSerialization.data(withJSONObject: row)
        data.append(10); data.append(0xff)
        try data.write(to: directory.appendingPathComponent("transcript.jsonl"))
        let history = UsageHistoryScanner.scan(home: home, now: now)
        let day = try #require(history.days.last)
        #expect(day.antigravity == Int.max)
        #expect(day.total == Int.max)
        #expect(day.observed)
    }
}
