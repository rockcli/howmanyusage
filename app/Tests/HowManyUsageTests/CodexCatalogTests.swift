import Foundation
import Testing
@testable import HowManyUsage

struct CodexCatalogTests {
    @Test func parserPreservesLiveSlugsEffortsAndRecordedServiceTiers() {
        let models = ["gpt-6.1-sol", "gpt-6-astra", "gpt-6.1-terra", "gpt-6-sol", "gpt-reserve",
                      "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "codex-auto-review"]
        for model in models {
            let effort: String? = ["gpt-6.1-sol", "gpt-6-astra", "gpt-6.1-terra"].contains(model)
                ? "ultra" : (model == "gpt-6-luna" ? "max" : nil)
            var session = CodexSpeed.Session()
            func row(_ seconds: Double, _ type: String, _ payload: [String: Any]) -> [String: Any] {
                ["timestamp": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds)),
                 "type": type, "payload": payload]
            }
            for (index, tier) in ["fast", "priority"].enumerated() {
                let time = Double(index * 20), turn = "turn-\(index)"
                session.consume(row(time, "event_msg", ["type": "task_started", "turn_id": turn]))
                var context: [String: Any] = ["turn_id": turn, "model": model, "service_tier": tier]
                if let effort { context["effort"] = effort }
                session.consume(row(time, "turn_context", context))
                session.consume(row(time + 4, "event_msg", ["type": "item_completed", "turn_id": turn,
                    "item": ["type": "AgentMessage"], "started_at_ms": (time + 1) * 1000, "completed_at_ms": (time + 4) * 1000]))
                session.consume(row(time + 4, "response_item", ["type": "message", "role": "assistant"]))
                session.consume(row(time + 5, "token_usage_record", ["response_id": "response-\(index)",
                    "turn_id": turn, "usage": ["output_tokens": 100]]))
            }
            #expect(session.samples.count == 2)
            #expect(session.samples.allSatisfy { $0.model == model && $0.effort == (effort ?? "unknown effort") && $0.rate == 25 })
        }
    }

    @Test func ultraKeepsConcreteModelVersionsSeparateInRows() {
        let now = Date(timeIntervalSince1970: 100_000)
        let samples = ["gpt-6.1-sol", "gpt-6-sol", "gpt-6.1-terra", "gpt-6-astra"].flatMap { model in
            ["low", "ultra"].map { effort in
                CodexSpeed.Sample(responseID: model + effort, model: model, effort: effort,
                    outputTokens: 100, seconds: 5, completedAt: now, waitSeconds: 1, outputSeconds: 4)
            }
        }
        let rows = CodexSpeed.Snapshot(samples: samples, now: now).rows
        #expect(Set(rows.map(\.name)) == ["gpt-6.1-sol", "gpt-6-sol", "gpt-6.1-terra", "gpt-6-astra"])
        #expect(rows.allSatisfy { $0.outputCount == 2 && $0.tps == 25 && $0.ttft == 1 })
    }
}
