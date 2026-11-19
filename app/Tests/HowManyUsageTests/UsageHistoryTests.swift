import Foundation
import Testing
@testable import HowManyUsage

struct UsageHistoryTests {
    @Test func sumsCumulativeCodexUsageAndDeduplicatesClaudeRequests() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = home.appendingPathComponent(".codex/sessions/2026/10/27")
        let claude = home.appendingPathComponent(".claude/projects/test")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let stamp = "2026-10-27T01:00:00Z"
        let rows: [[String: Any]] = [
            ["timestamp": stamp, "type": "event_msg", "payload": ["type": "user_message", "message": "hello"]],
            ["timestamp": stamp, "type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 100, "output_tokens": 20]]]],
            ["timestamp": stamp, "type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 100, "output_tokens": 20]]]],
            ["timestamp": stamp, "type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 150, "output_tokens": 30]]]]
        ]
        func jsonl(_ records: [[String: Any]]) throws -> String { try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") }
        try jsonl(rows).write(to: codex.appendingPathComponent("rollout.jsonl"), atomically: true, encoding: .utf8)
        let c: [String: Any] = ["timestamp": stamp, "type": "assistant", "requestId": "same", "message": ["usage": ["input_tokens": 10, "cache_read_input_tokens": 40, "output_tokens": 5]]]
        try jsonl([c, c]).write(to: claude.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        try jsonl([c]).write(to: claude.appendingPathComponent("copy.jsonl"), atomically: true, encoding: .utf8)
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-27T02:00:00Z"))
        var updates: [UsageHistory] = []
        let history = UsageHistoryScanner.scan(home: home, now: now, progress: { updates.append($0) })
        let today = try #require(history.days.last)
        #expect(history.days.count == 98)
        #expect(today.codex == 180)
        #expect(today.claude == 55)
        #expect(today.prompts == 1)
        #expect(today.observed)
        #expect(!history.days[0].observed)
        #expect(updates.count >= 2)
        #expect(updates.first?.days.last?.total == 0)
        #expect(updates.last?.days.last?.total == today.total)
        let snapshot = try #require(UsageHistoryScanner.loadSnapshot(home: home, now: now))
        #expect(snapshot.days.last?.total == today.total)
        var reads: [URL] = []
        let reused = UsageHistoryScanner.scan(home: home, now: now, onFileRead: { reads.append($0) })
        #expect(reads.isEmpty)
        #expect(reused.days.last?.total == today.total)
        let codexFile = codex.appendingPathComponent("rollout.jsonl")
        try (jsonl(rows) + "\n" + jsonl([rows[0]])).write(to: codexFile, atomically: true, encoding: .utf8)
        reads.removeAll()
        let updated = UsageHistoryScanner.scan(home: home, now: now, onFileRead: { reads.append($0) })
        #expect(reads.map { $0.resolvingSymlinksInPath() } == [codexFile.resolvingSymlinksInPath()])
        #expect(updated.days.last?.prompts == 2)
        #expect(updated.days.last?.claude == 55)
        let tomorrow = try #require(ISO8601DateFormatter().date(from: "2026-10-28T02:00:00Z"))
        reads.removeAll()
        let shifted = UsageHistoryScanner.scan(home: home, now: tomorrow, onFileRead: { reads.append($0) })
        #expect(reads.isEmpty)
        #expect(shifted.days[96].total == today.total)
    }

    @Test func scansAntigravityCLIAndClientsAndDeduplicatesMigratedConversations() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let clientConv = home.appendingPathComponent(".gemini/antigravity/brain/conv-shared/.system_generated/logs")
        let ideConv = home.appendingPathComponent(".gemini/antigravity-ide/brain/conv-shared/.system_generated/logs")
        let cliConv = home.appendingPathComponent(".gemini/antigravity-cli/brain/conv-cli/.system_generated/logs")
        let subagentConv = home.appendingPathComponent(".gemini/antigravity/brain/conv-subagent/.system_generated/logs")
        let backupConv = home.appendingPathComponent(".gemini/antigravity-backup/brain/conv-backup/.system_generated/logs")
        for dir in [clientConv, ideConv, cliConv, subagentConv, backupConv] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let stamp = "2026-10-27T01:00:00Z"
        func jsonl(_ records: [[String: Any]]) throws -> String {
            try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        }
        // Older copy in antigravity-ide (migrated snapshot with 1 step)
        let oldShared: [[String: Any]] = [
            ["step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT", "created_at": stamp, "content": "hi"],
            ["step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "created_at": stamp, "input_tokens": 100, "cache_read_tokens": 200, "output_tokens": 50]
        ]
        let ideFile = ideConv.appendingPathComponent("transcript.jsonl")
        try jsonl(oldShared).write(to: ideFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: ISO8601DateFormatter().date(from: "2026-10-27T01:05:00Z")!], ofItemAtPath: ideFile.path)

        // Newer copy of same conv-shared in antigravity desktop client (with duplicate step 1 and new step 2)
        let newShared: [[String: Any]] = [
            ["step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT", "created_at": stamp, "content": "hi"],
            ["step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "created_at": stamp, "input_tokens": 100, "cache_read_tokens": 200, "output_tokens": 40],
            ["step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "created_at": stamp, "input_tokens": 100, "cache_read_tokens": 200, "output_tokens": 50],
            ["step_index": 2, "source": "MODEL", "type": "PLANNER_RESPONSE", "created_at": stamp, "input_tokens": 50, "cache_read_tokens": 300, "cache_write_tokens": 10, "output_tokens": 40]
        ]
        let clientFile = clientConv.appendingPathComponent("transcript.jsonl")
        try jsonl(newShared).write(to: clientFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: ISO8601DateFormatter().date(from: "2026-10-27T01:10:00Z")!], ofItemAtPath: clientFile.path)

        // CLI conversation in antigravity-cli
        let cliRows: [[String: Any]] = [
            ["step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT", "created_at": stamp, "content": "cli prompt"],
            ["step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "created_at": stamp, "input_tokens": 80, "cache_read_tokens": 20, "output_tokens": 25]
        ]
        try jsonl(cliRows).write(to: cliConv.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

        // Subagent conversation (system prompt should not count as human prompt, tokens should count)
        let subRows: [[String: Any]] = [
            ["step_index": 0, "source": "SYSTEM", "type": "SYSTEM_MESSAGE", "created_at": stamp, "agent_name": "research", "content": "subagent task"],
            ["step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "created_at": stamp, "input_tokens": 60, "cache_read_tokens": 0, "output_tokens": 15]
        ]
        try jsonl(subRows).write(to: subagentConv.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

        // Backup directory must be ignored
        try jsonl(cliRows).write(to: backupConv.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-27T02:00:00Z"))
        let history = UsageHistoryScanner.scan(home: home, now: now)
        let today = try #require(history.days.last)
        // newShared: (100+200+50) + (50+300+10+40) = 350 + 400 = 750
        // cliRows: 80+20+25 = 125
        // subRows: 60+0+15 = 75
        // total antigravity = 750 + 125 + 75 = 950; prompts = 2 (client + cli, excluding subagent & backup)
        #expect(today.antigravity == 950)
        #expect(today.total == 950)
        #expect(today.prompts == 2)
        #expect(today.observed)
    }
}
