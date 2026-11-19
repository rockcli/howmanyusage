import Foundation
import Testing
@testable import HowManyUsage

struct DshSpeedTests {
    private func jsonl(_ records: [[String: Any]]) throws -> String {
        try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
    }

    @Test func antigravityModelSelectionPreservesDecimalsAndMixedModelNames() {
        let cases: [(raw: String, expected: String)] = [
            ("Gemini 3.8 Flash", "gemini-3.8-flash"),
            ("Claude Opus 5.5", "Claude Opus 5.5"),
            ("Orchestrator", "gemini-orchestrator"),
        ]
        for (model, expected) in cases {
            let selected = AntigravitySpeedScanner.extractModel(from: [
                "type": "USER_INPUT",
                "content": "The user changed setting `Model Selection` from None to \(model) (High). No need to comment."
            ])
            #expect(selected?.model == expected)
            #expect(selected?.effort == "High")
        }
    }

    @Test func v4NestedStreamSeparatesWaitAndOutputAndPreservesModelID() throws {
        let record: [String: Any] = ["type": "assistant/message", "time": 7100,
            "data": ["turn": 1, "step": 1, "usage": ["inputTokens": 90000, "cacheReadTokens": 10000, "outputTokens": 100, "totalTokens": 100100], "stream": [
                ["type": "chunk", "time": 1100, "chunk": ["type": "block-start", "blockType": "reasoning"]],
                ["type": "chunk", "time": 3000, "chunk": ["type": "reasoning-delta", "text": "x"]],
                ["type": "chunk", "time": 7000, "chunk": ["type": "usage", "usage": ["outputTokens": 100]]]
            ]]]
        let text = try jsonl([
            ["type": "session", "id": "session"],
            ["type": "step/start", "time": 1000, "data": ["turn": 1, "step": 1]],
            ["type": "request/context", "data": ["provider": "deepseek-official", "model": "deepseek-4.1-flash"]],
            record, record
        ])
        let samples = DshSpeed.parse(text, sourceID: "file")
        #expect(samples.count == 1)
        #expect(samples.first?.model == "deepseek-4.1-flash")
        #expect(samples.first?.waitSeconds == 2)
        #expect(samples.first?.outputSeconds == 4)
        #expect(samples.first?.rate == 25)
        #expect(samples.first?.cacheUsage == .init(read: 10000, input: 100000))
    }

    @Test func flatStreamHonorsStepBoundaryAndDoesNotGuessAnAliasVersion() throws {
        let text = try jsonl([
            ["type": "request/context", "data": ["provider": "deepseek-official", "model": "deepseek-flash"]],
            ["type": "tool/result", "time": 1000],
            ["type": "step/start", "time": 60000, "data": ["turn": 2, "step": 3]],
            ["type": "assistant/chunk", "time": 61000, "data": ["turn": 2, "step": 3, "chunk": ["type": "reasoning-delta"]]],
            ["type": "assistant/chunk", "time": 66000, "data": ["turn": 2, "step": 3, "chunk": ["type": "usage"]]],
            ["type": "assistant/message", "time": 67000, "data": ["turn": 2, "step": 3, "usage": ["outputTokens": 1000]]]
        ])
        let sample = try #require(DshSpeed.parse(text, sourceID: "file").first)
        #expect(sample.model == "deepseek-flash")
        #expect(sample.waitSeconds == 1)
        #expect(sample.outputSeconds == 5)
        #expect(sample.rate == 200)
    }

    @Test func noStreamOrWrongProviderNeverProducesFakeTiming() throws {
        let text = try jsonl([
            ["type": "request/context", "data": ["provider": "other", "model": "unrelated"]],
            ["type": "step/start", "time": 1000, "data": ["turn": 1, "step": 1]],
            ["type": "assistant/message", "time": 5000, "data": ["turn": 1, "step": 1, "usage": ["outputTokens": 100]]]
        ])
        #expect(DshSpeed.parse(text, sourceID: "file").isEmpty)
    }

    @Test func claudeModelsComeFromActualAssistantRecordsWithinOneDay() throws {
        let now = Date(timeIntervalSince1970: 100000)
        let timestamp = ISO8601DateFormatter().string(from: now)
        let old = ISO8601DateFormatter().string(from: now.addingTimeInterval(-86401))
        let text = try jsonl([
            ["type": "assistant", "timestamp": timestamp, "requestedModel": "claude-opus-5-5", "message": ["model": "claude-sonnet-5-5", "usage": ["output_tokens": 300]]],
            ["type": "assistant", "timestamp": old, "message": ["model": "claude-opus-5-5"]],
            ["type": "user", "timestamp": timestamp, "message": ["model": "claude-haiku-4-5"]]
        ])
        let models = ClaudeModelScanner.models(in: Data(text.utf8), now: now)
        #expect(Set(models.keys) == ["claude-sonnet-5-5"])
        let snapshot = CodexSpeed.Snapshot(observedModels: models, now: now)
        #expect(snapshot.observedModels["claude-sonnet-5-5"] != nil)
        #expect(snapshot.rows.isEmpty)
        #expect(snapshot.rows.first?.ttft == nil)
        #expect(snapshot.rows.first?.tps == nil)
    }

    @Test func antigravityTranscriptExtractsModelSpeedAndCacheUsage() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-04T13:20:00Z"))
        let text = try jsonl([
            ["step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT", "created_at": "2026-11-04T13:18:27Z",
             "content": "<USER_REQUEST>\nhi\n</USER_REQUEST>\n<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Gemini 4 Argon (Medium). No need to comment.\n</USER_SETTINGS_CHANGE>"],
            ["step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "created_at": "2026-11-04T13:18:27Z",
             "input_tokens": 2000, "cache_read_tokens": 8000, "output_tokens": 250],
            ["step_index": 2, "source": "MODEL", "type": "GENERIC", "created_at": "2026-11-04T13:18:32Z",
             "content": "tool result"],
            ["step_index": 3, "source": "MODEL", "type": "PLANNER_RESPONSE", "created_at": "2026-11-04T13:18:34Z",
             "input_tokens": 1000, "cache_read_tokens": 9000, "output_tokens": 120]
        ])
        let parsed = AntigravitySpeedScanner.parse(data: Data(text.utf8), sourceID: "conv-1", now: now)
        #expect(Set(parsed.models.keys) == ["gemini-4-argon"])
        #expect(parsed.samples.count == 2)
        let snapshot = CodexSpeed.Snapshot(samples: parsed.samples, observedModels: parsed.models, now: now)
        let row = try #require(snapshot.rows.first { $0.name == "gemini-4-argon" })
        #expect(row.tps == 50) // 250 tokens / 5s (step 3 has seconds=0 so excluded from tps)
        #expect(row.cachePercent == 85) // (8000 + 9000) / (10000 + 10000) = 85%
    }

    @Test func antigravityNormalizesSimilarModelNamesIntoSingleRows() {
        #expect(AntigravitySpeedScanner.splitModelAndEffort("Gemini 4 Neon (Medium)")?.model == "gemini-4-neon")
        #expect(AntigravitySpeedScanner.splitModelAndEffort("gemini-4-neon-medium")?.model == "gemini-4-neon")
        #expect(AntigravitySpeedScanner.splitModelAndEffort("Gemini 4 Hydrogen (Orchestrator)")?.model == "gemini-4-hydrogen")
        #expect(AntigravitySpeedScanner.splitModelAndEffort("gemini-4-hydrogen-tiered-high")?.model == "gemini-4-hydrogen")
        #expect(AntigravitySpeedScanner.splitModelAndEffort("Orchestrator (Carbon)")?.model == "gemini-orchestrator")
        #expect(AntigravitySpeedScanner.splitModelAndEffort("Orchestrator (Argon)")?.model == "gemini-orchestrator")
        #expect(AntigravitySpeedScanner.splitModelAndEffort("gemini-pro-orchestrator")?.model == "gemini-orchestrator")
        #expect(AntigravitySpeedScanner.splitModelAndEffort("gemini-flash-worker-agy")?.model == "gemini-flash-worker")
    }

    @Test func agySpeedFileOverridesTranscriptTimingAndPreservesCache() throws {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("agy-speed.json")
        let payload: [String: Any] = [
            "samples": [
                [
                    "id": "conv-1:1",
                    "model": "Gemini 4 Hydrogen (Medium)",
                    "outputTokens": 500,
                    "ttft": 2.0,
                    "stream": 3.0,
                    "completedAt": now.timeIntervalSince1970 - 60
                ],
                [
                    "id": "conv-1:2",
                    "model": "Gemini 4 Hydrogen (Orchestrator)",
                    "outputTokens": 1000,
                    "ttft": 4.0,
                    "stream": 6.0,
                    "completedAt": now.timeIntervalSince1970 - 30
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: file)

        let transcript = [
            CodexSpeed.Sample(
                responseID: "agy:conv-1:1",
                model: "gemini-4-hydrogen",
                effort: "Medium",
                outputTokens: 500,
                seconds: 100,
                completedAt: now.addingTimeInterval(-60),
                includesWait: true,
                cacheUsage: CodexSpeed.CacheUsage.antigravity(["input_tokens": 1000, "cache_read_tokens": 9000])
            )
        ]
        let fileSamples = AntigravitySpeedFile.samples(url: file, now: now)
        let merged = AntigravitySpeedFile.merge(transcriptSamples: transcript, fileSamples: fileSamples)
        let snapshot = CodexSpeed.Snapshot(samples: merged, now: now)
        let row = try #require(snapshot.rows.first { $0.name == "gemini-4-hydrogen" })
        #expect(row.ttft == 3)
        #expect(row.tps == 500.0 / 3.0) // pure stream: (500 + 1000) / (3 + 6)
        #expect(!row.includesWait)
        #expect(row.cachePercent == 90)
    }

    @Test func agySpeedFileMergeHandlesDuplicateIDsWithoutTrappingAndKeepsHigherTokens() {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let dupTranscript = [
            CodexSpeed.Sample(responseID: "agy:c:1", model: "gemini-4-neon", effort: "medium",
                              outputTokens: 200, seconds: 10, completedAt: now.addingTimeInterval(-20),
                              includesWait: true, cacheUsage: .init(read: 800, input: 1000)),
            CodexSpeed.Sample(responseID: "agy:c:1", model: "gemini-4-neon", effort: "medium",
                              outputTokens: 600, seconds: 12, completedAt: now.addingTimeInterval(-10),
                              includesWait: true, cacheUsage: .init(read: 900, input: 1000))
        ]
        let fileSamples = [
            CodexSpeed.Sample(responseID: "agy:c:1", model: "gemini-4-neon", effort: "medium",
                              outputTokens: 300, seconds: 5, completedAt: now.addingTimeInterval(-15),
                              waitSeconds: 2, outputSeconds: 3, includesWait: false)
        ]
        let merged = AntigravitySpeedFile.merge(transcriptSamples: dupTranscript, fileSamples: fileSamples)
        #expect(merged.count == 1)
        #expect(merged.first?.outputTokens == 600)
        #expect(merged.first?.outputSeconds == 3)
        #expect(merged.first?.cacheUsage == .init(read: 900, input: 1000))
    }
}
