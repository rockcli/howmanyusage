import Foundation
import Testing
@testable import HowManyUsage

/// Server-side Codex attribution: client classification, endpoint parsing, the
/// local/cloud split, and the dilution guard that keeps a cloud-heavy window from
/// re-anchoring the local dollar-per-percent rate.
struct CodexServerUsageTests {

    // MARK: - Client classification

    @Test func testClientClassificationMatchesVerifiedAccountBehaviour() {
        // Verified on 2026-10-08: CODEX_DESKTOP_APP daily tokens (100.5M) track the
        // local rollout volume (92.6M); CODEX_WORK_WEB only appears on cloud-only days.
        #expect(CodexServerUsage.Source.classify(clientId: "CODEX_DESKTOP_APP") == .local)
        #expect(CodexServerUsage.Source.classify(clientId: "CODEX_SERVICE_EXEC") == .local)
        #expect(CodexServerUsage.Source.classify(clientId: "CODEX_WORK_WEB") == .cloud)
        #expect(CodexServerUsage.Source.classify(clientId: "CODEX_WORK_DESKTOP") == .cloud)
        #expect(CodexServerUsage.Source.classify(clientId: "CODEX_UNKNOWN_DEFAULT") == .other)
        #expect(CodexServerUsage.Source.classify(clientId: nil) == .other)
    }

    // MARK: - Parsing

    @Test func testDailyCountsParseClientSplit() async throws {
        let json = """
        {"group_by":"day","data":[
          {"date":"2026-10-08","totals":{},"clients":[
            {"client_id":"CODEX_WORK_WEB","uncached_text_input_tokens":11582388,
             "cached_text_input_tokens":245092608,"text_output_tokens":1299299},
            {"client_id":"CODEX_DESKTOP_APP","uncached_text_input_tokens":6126932,
             "cached_text_input_tokens":93431296,"text_output_tokens":961818}
          ]}
        ]}
        """
        let rows = try await CodexServerUsage.parseDailyCounts(Data(json.utf8))
        #expect(rows.count == 1)
        let day = try #require(rows.first)
        #expect(day.date == "2026-10-08")
        // 11,582,388 + 245,092,608 + 1,299,299
        #expect(day.cloud.total == 257_974_295)
        // 6,126,932 + 93,431,296 + 961,818
        #expect(day.local.total == 100_520_046)
        #expect(day.total.total == 358_494_341)
    }

    @Test func testDailyCountsTolerateMissingAndNumericStringFields() async throws {
        let json = """
        {"data":[{"date":"2026-10-09","clients":[
          {"client_id":"CODEX_WORK_WEB","cached_text_input_tokens":"1000"},
          {"client_id":"CODEX_DESKTOP_APP"},
          {"uncached_text_input_tokens":5}
        ]}]}
        """
        let rows = try await CodexServerUsage.parseDailyCounts(Data(json.utf8))
        let day = try #require(rows.first)
        #expect(day.cloud.total == 1000)
        #expect(day.local.total == 0)
        #expect(day.other.total == 5)
    }

    @Test func testThreadUsageParsesPercentAndStatus() async throws {
        let json = """
        {"data_as_of":"2026-10-09T07:50:34Z","threads":[
          {"thread_id":"01a11a1f-fa4a-72a7-808a-d477cc495038","weekly_limit_percent":9.369,
           "data_status":"partial","usage_source":"included_plan",
           "groups":[{"model":"gpt-6.1-sol","reasoning_effort":"medium","weekly_limit_percent":7.882}]},
          {"thread_id":"01a12083-7722-76a1-91a1-aa0c41d708d1","weekly_limit_percent":null,
           "data_status":"unavailable"}
        ]}
        """
        let rows = try await CodexServerUsage.parseThreadUsage(Data(json.utf8))
        #expect(rows.count == 2)
        #expect(rows[0].pct == 9.369)
        #expect(rows[0].status == "partial")
        #expect(rows[1].pct == 0)
        #expect(rows[1].status == "unavailable")
    }

    // MARK: - Attribution

    @Test func testCloudQuotaPctCountsOnlyConversationsWithoutLocalRollouts() {
        let snapshot = CodexServerUsage.Snapshot(
            fetchedAt: Date(),
            days: [],
            conversations: [
                .init(id: "cloud-a", weeklyPct: 9.369, status: "partial", hasLocalRollout: false),
                .init(id: "cloud-b", weeklyPct: 10.822, status: "partial", hasLocalRollout: false),
                .init(id: "local-a", weeklyPct: 3.97, status: "partial", hasLocalRollout: true),
                .init(id: "local-cli", weeklyPct: 0, status: "unavailable", hasLocalRollout: true),
            ],
            cloudQuotaPct: 20.191,
            localQuotaPct: 3.97
        )
        #expect(abs((snapshot.cloudQuotaPct ?? 0) - 20.191) < 0.001)
        // 77 used - 20.191 cloud - 3.97 local = 52.839 unattributed
        let unattributed = try? #require(snapshot.unattributedQuotaPct(usedPercent: 77))
        #expect(abs((unattributed ?? 0) - 52.839) < 0.01)
        let share = try? #require(snapshot.cloudQuotaShare(usedPercent: 77))
        #expect(abs((share ?? 0) - 20.191 / 77) < 0.001)
    }

    @Test func testCloudQuotaShareIsNilWhenAttributionIsUnknown() {
        let snapshot = CodexServerUsage.Snapshot(fetchedAt: Date(), days: [])
        #expect(snapshot.cloudQuotaPct == nil)
        #expect(snapshot.cloudQuotaShare(usedPercent: 77) == nil)   // unknown, not zero
        #expect(snapshot.unattributedQuotaPct(usedPercent: 77) == nil)
        #expect(snapshot.sourceLine(usedPercent: 77) == nil)
    }

    @Test func testTokenSplitAndSourceLine() {
        let snapshot = CodexServerUsage.Snapshot(
            fetchedAt: Date(),
            days: [
                .init(date: "2026-10-07", local: .init(uncached: 0, cached: 291_382, output: 0),
                      cloud: .init(uncached: 0, cached: 204_671_498, output: 0), other: .zero),
                .init(date: "2026-10-08", local: .init(uncached: 0, cached: 100_520_046, output: 0),
                      cloud: .init(uncached: 0, cached: 257_974_295, output: 0), other: .zero),
            ],
            conversations: [.init(id: "c", weeklyPct: 37.52, status: "partial", hasLocalRollout: false)],
            cloudQuotaPct: 37.52,
            localQuotaPct: nil
        )
        // 462,645,541 cloud / 563,457,221 total
        let share = try? #require(snapshot.cloudTokenShare())
        #expect(abs((share ?? 0) - 0.821) < 0.002)
        let line = try? #require(snapshot.sourceLine(usedPercent: 77))
        #expect(line?.contains("cloud 82% tok") == true)
        #expect(line?.contains("cloud chats 38% of quota") == true)
        #expect(snapshot.cloudQuotaText(usedPercent: 77) == "cloud chats 38% of quota")
        // 77 - 37.52 = 39.48
        #expect(line?.contains("unattributed 39% of quota") == true)
    }

    // MARK: - Dilution guard

    @Test func testDilutionThresholdKeepsCloudHeavyWindowsFromReanchoring() {
        let threshold = CodexServerUsage.Snapshot.dilutionThreshold
        // Current window: ≥37.5% of the quota is cloud conversations -> diluted.
        #expect((37.52 / 77) >= threshold)
        // A mostly-local window stays usable.
        #expect(!((3.0 / 77) >= threshold))
        // Unknown attribution must not be treated as "diluted" (keeps legacy behaviour).
        #expect(!((Double?.none ?? 0) >= threshold))
    }

    // MARK: - Id harvesting

    @Test func testUUIDHelpers() {
        let line = Substring("""
        2026-10-09T08:29:21Z info VM lifecycle environmentId=ccarenv_b64_X hostId=durable \
        conversationId=01a11a1f-fa4a-72a7-808a-d477cc495038 vmEvent=environment_disconnected
        """)
        #expect(CodexServerUsage.uuid(after: "conversationId=", in: line)
            == "01a11a1f-fa4a-72a7-808a-d477cc495038")
        #expect(CodexServerUsage.uuid(after: "conversationId=", in: Substring("no id here")) == nil)
        let resume = "rollout-2026-10-09T19-59-00-01a12044-c2fc-7473-8aaa-493d7c1489a1_01a12087-e973-7663-a0fd-bdabc0c497ef.jsonl"
        #expect(CodexServerUsage.uuids(in: resume).count == 2)
        #expect(CodexServerUsage.isUUID("01a12087-e973-7663-a0fd-bdabc0c497ef"))
        #expect(!CodexServerUsage.isUUID("01a12087-e973-7663-a0fd-bdabc0c497e"))
        #expect(!CodexServerUsage.isUUID("01a12087xe973-7663-a0fd-bdabc0c497ef"))
    }

    @Test func testHarvestCollectsEveryConversationReference() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-server-usage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("codex-desktop-2026-10-09.log")
        try """
        2026-10-09T01:01:03Z info VM lifecycle environmentId=ccarenv_b64_X hostId=durable conversationId=01a11a1f-fa4a-72a7-808a-d477cc495038 vmEvent=environment_connected
        2026-10-09T03:54:01Z error Request failed conversationId=01a11787-453d-700a-8f53-c57a8e1640fb method=thread/resume
        2026-10-09T04:00:00Z info local thread conversationId=01a12083-7722-76a1-91a1-aa0c41d708d1
        """.write(to: log, atomically: true, encoding: .utf8)
        let ids = CodexServerUsage.harvestConversationIDs(
            since: Date().addingTimeInterval(-3600), logsRoot: root
        )
        // Every conversationId is collected; the local/cloud split happens later, by
        // checking whether this Mac has a rollout file for the id.
        #expect(ids.count == 3)
        #expect(ids.contains("01a11a1f-fa4a-72a7-808a-d477cc495038"))   // cloud env line
        #expect(ids.contains("01a11787-453d-700a-8f53-c57a8e1640fb"))   // resume line
        #expect(ids.contains("01a12083-7722-76a1-91a1-aa0c41d708d1"))   // plain local line
    }

    // MARK: - Backtest against the observed 2026-10-04..10-09 data

    @Test func testBacktestCloudOnlyWindowIsFullyAttributedToCloudTokens() {
        // 2026-10-04..10-07: official surface breakdown said work_cca 61.49%, local
        // rollouts had zero priced turns, and the server reported 100% WORK_WEB tokens.
        let days = [
            CodexServerUsage.Day(date: "2026-10-04", local: .zero, cloud: .init(uncached: 0, cached: 183_773_099, output: 0), other: .zero),
            CodexServerUsage.Day(date: "2026-10-05", local: .zero, cloud: .init(uncached: 0, cached: 126_252_760, output: 0), other: .zero),
            CodexServerUsage.Day(date: "2026-10-06", local: .zero, cloud: .init(uncached: 0, cached: 166_867_413, output: 0), other: .zero),
            CodexServerUsage.Day(date: "2026-10-07", local: .init(uncached: 0, cached: 291_382, output: 0), cloud: .init(uncached: 0, cached: 204_671_498, output: 0), other: .zero),
        ]
        let snapshot = CodexServerUsage.Snapshot(fetchedAt: Date(), days: days,
                                                 conversations: [], cloudQuotaPct: 61.49)
        let share = try? #require(snapshot.cloudTokenShare())
        #expect((share ?? 0) > 0.99)
        // 61.49 of a 61.49% window is cloud: nothing left for the local rate to claim.
        #expect(snapshot.unattributedQuotaPct(usedPercent: 61.49) == 0)
    }

    @Test func testBacktestMixedDaySplitsCloudAndLocal() {
        // 2026-10-08 was the first mixed day: 72% of tokens came from the cloud surface.
        let day = CodexServerUsage.Day(date: "2026-10-08",
                                       local: .init(uncached: 0, cached: 100_520_046, output: 0),
                                       cloud: .init(uncached: 0, cached: 257_974_295, output: 0),
                                       other: .zero)
        let snapshot = CodexServerUsage.Snapshot(fetchedAt: Date(), days: [day])
        #expect(abs((snapshot.cloudTokenShare() ?? 0) - 0.7196) < 0.001)
    }

    // MARK: - Dilution evidence and the clean anchor

    @Test func testDilutionEvidenceUsesAttributionThenFallsBackToTokenShare() {
        var snapshot = CodexServerUsage.Snapshot(fetchedAt: Date(), days: [
            .init(date: "d", local: .init(uncached: 0, cached: 40, output: 0),
                  cloud: .init(uncached: 0, cached: 60, output: 0), other: .zero),
        ])
        // No attribution yet: the token share alone marks the window as untrustworthy for
        // calibration. It is a *flag*, never used to apportion quota.
        #expect(snapshot.cloudQuotaShare(usedPercent: 80) == nil)
        #expect(abs(snapshot.dilutionEvidence(usedPercent: 80) - 0.6) < 0.001)
        #expect(snapshot.isDiluted(usedPercent: 80))

        // With attribution present the larger of the two signals wins.
        snapshot.cloudQuotaPct = 8
        #expect(abs(snapshot.dilutionEvidence(usedPercent: 80) - 0.6) < 0.001)

        // A local-only window is not diluted, even at high usage.
        snapshot = CodexServerUsage.Snapshot(fetchedAt: Date(), days: [
            .init(date: "d", local: .init(uncached: 0, cached: 100, output: 0),
                  cloud: .zero, other: .zero),
        ], conversations: [], cloudQuotaPct: 8)
        #expect(abs(snapshot.dilutionEvidence(usedPercent: 80) - 0.1) < 0.001)
        #expect(!snapshot.isDiluted(usedPercent: 80))
    }

    @Test func testDilutedWindowKeepsTheLastCleanAnchor() {
        // A window this machine explains sets the anchor.
        var value = QuotaValueEstimate.updated(nil, resetEpoch: 1, observedPercent: 40,
                                               rawMonthlyUSD: 1100, isDiluted: false)
        #expect(abs((value?.cleanMonthlyUSD ?? 0) - 1100) < 0.01)

        // Cloud-heavy window: the diluted raw value is withheld, so nothing moves.
        value = QuotaValueEstimate.updated(value, resetEpoch: 1, observedPercent: 79,
                                           rawMonthlyUSD: nil, isDiluted: true)
        #expect(abs((value?.cleanMonthlyUSD ?? 0) - 1100) < 0.01)
        #expect(abs((value?.monthlyUSD ?? 0) - 1100) < 0.01)

        // The next undiluted window may refresh the anchor again.
        value = QuotaValueEstimate.updated(value, resetEpoch: 2, observedPercent: 30,
                                           rawMonthlyUSD: 900, isDiluted: false)
        #expect(abs((value?.cleanMonthlyUSD ?? 0) - 900) < 0.01)
    }

    @Test func testDilutedWriteIsRefusedEvenWhenRawValueIsProvided() {
        // The choke point must ignore a raw value while the window is diluted, otherwise
        // `monthlyUSD` would carry the diluted number into the next reset anchor.
        let value = QuotaValueEstimate.updated(nil, resetEpoch: 1, observedPercent: 79,
                                               rawMonthlyUSD: nil, isDiluted: true)
        #expect(value == nil)
        // Epochs must differ by more than the reset tolerance (300 s) to model a reset.
        let seeded = QuotaValueEstimate.updated(nil, resetEpoch: 1_000, observedPercent: 30,
                                                rawMonthlyUSD: 900, isDiluted: false)
        let after = QuotaValueEstimate.updated(seeded, resetEpoch: 2_000, observedPercent: 79,
                                               rawMonthlyUSD: nil, isDiluted: true)
        #expect(abs((after?.monthlyUSD ?? 0) - 900) < 0.01)
        #expect(abs((after?.previousMonthlyUSD ?? 0) - 900) < 0.01)
    }

    @Test func testDilutedWindowWithoutAnyCleanAnchorShowsNothing() {
        // Better to show no estimate than one known to be diluted.
        #expect(QuotaValueEstimate.updated(nil, resetEpoch: 1, observedPercent: 50,
                                           rawMonthlyUSD: nil, isDiluted: true) == nil)
    }

    // MARK: - Window scoping (weekly_limit_percent is per-window, not cumulative)

    @Test func testCreationDateDecodesUUIDv7() {
        // 2026-10-08T06:07Z from the real id 01a11a1f-fa4a-72a7-808a-d477cc495038.
        let date = try? #require(CodexServerUsage.creationDate(threadID: "01a11a1f-fa4a-72a7-808a-d477cc495038"))
        let text = ISO8601DateFormatter().string(from: date ?? Date())
        #expect(text.hasPrefix("2026-10-08"))
        // A v4 id has no embedded timestamp.
        #expect(CodexServerUsage.creationDate(threadID: "885223c3-dd41-44bf-a70e-3cf97edb0c3f") == nil)
    }

    @Test func testAttributeExcludesEarlierWindowsAndSplitsByLocalRollout() {
        let rows = [
            CodexServerUsage.ThreadRow(id: "01a11a1f-fa4a-72a7-808a-d477cc495038", pct: 9.369, status: "partial"),   // in window, cloud
            CodexServerUsage.ThreadRow(id: "01a11a4d-29e7-73f6-9954-4b3854751014", pct: 1.839, status: "partial"),   // in window, cloud
            CodexServerUsage.ThreadRow(id: "01a11a38-86eb-7c40-b9c4-2e967d1db2fb", pct: 1.321, status: "partial"),   // in window, local rollout
            CodexServerUsage.ThreadRow(id: "01a0f33e-2cc6-7822-9433-44774a1cf29d", pct: 42.422, status: "partial"),  // older window -> excluded
        ]
        let windowStart = ISO8601DateFormatter().date(from: "2026-10-07T11:30:58+08:00")
        let result = CodexServerUsage.attribute(
            rows: rows,
            localIDs: ["01a11a38-86eb-7c40-b9c4-2e967d1db2fb"],
            windowStart: windowStart
        )
        #expect(result.conversations.count == 3)
        #expect(result.excluded == 1)
        // The 42.4% conversation belongs to an earlier week and must not be summed in;
        // doing so produced 115% of a single window before this filter existed.
        #expect(abs((result.cloudPct ?? 0) - 11.208) < 0.001)
        #expect(abs((result.localPct ?? 0) - 1.321) < 0.001)
    }

    @Test func testAttributeWithoutWindowStartExcludesEverything() {
        let rows = [CodexServerUsage.ThreadRow(id: "whatever", pct: 2, status: "partial")]
        let result = CodexServerUsage.attribute(rows: rows, localIDs: [], windowStart: nil)
        #expect(result.conversations.isEmpty)
        #expect(result.excluded == 1)
        #expect(result.cloudPct == nil)
    }

    // MARK: - Cloud tokens priced at Sol 6.1 (the chosen basis)

    @Test func testCloudTokensArePricedAtSolRates() {
        // 10M uncached + 100M cached + 1M output at $2 / $0.10 / $10 per MTok.
        let cloud = CodexServerUsage.TokenCounts(uncached: 10_000_000, cached: 100_000_000, output: 1_000_000)
        let usd = cloud.usd(using: CodexValue.cloudPricing)
        #expect(abs(usd - (20 + 10 + 10)) < 0.001)
        // Sanity: the basis really is GPT-6.1 Sol.
        #expect(CodexValue.cloudPricing.input == 2.0e-6)
        #expect(CodexValue.cloudPricing.cached == 0.1e-6)
        #expect(CodexValue.cloudPricing.output == 10.0e-6)
    }

    @Test func testCloudUSDIsScopedToTheCurrentWindow() {
        let snapshot = CodexServerUsage.Snapshot(fetchedAt: Date(), days: [
            CodexServerUsage.Day(date: "2026-10-07", local: .zero,
                                 cloud: .init(uncached: 0, cached: 1_000_000_000, output: 0), other: .zero),
            CodexServerUsage.Day(date: "2026-10-08", local: .zero,
                                 cloud: .init(uncached: 0, cached: 100_000_000, output: 0), other: .zero),
        ])
        // Window starts mid-day on 10-07: prorate that day, then add the full 10-08 day.
        let start = ISO8601DateFormatter().date(from: "2026-10-07T11:30:58+08:00")
        let scoped = try? #require(snapshot.cloudUSD(windowStart: start, using: CodexValue.cloudPricing, now: ISO8601DateFormatter().date(from: "2026-10-09T00:00:00Z")!))
        let fraction: Double = 73742.0 / 86400.0
        #expect(abs((scoped ?? 0) - (100 * fraction + 10)) < 0.001)
        // Unknown scope must never charge previous-window consumption.
        #expect(snapshot.cloudUSD(windowStart: nil, using: CodexValue.cloudPricing) == nil)
    }

    @Test func testMultipleIsAlwaysProducedEvenForACloudHeavyWindow() {
        // Current window shape: $30.85 of local tokens + cloud priced at Sol 6.1,
        // paired with the account's 80% — the point of the change is that a number
        // always comes out, with the cloud share no longer a blind spot.
        let cloud = CodexServerUsage.TokenCounts(uncached: 20_000_000, cached: 440_000_000, output: 2_500_000)
        let cloudUSD = cloud.usd(using: CodexValue.cloudPricing)
        // 20M x $2 + 440M x $0.10 + 2.5M x $10 = $40 + $44 + $25 = $109
        #expect(abs(cloudUSD - 109) < 0.001)
        let monthly = try? #require(CodexValue.extrapolate(costSoFar: 30.85 + cloudUSD, pctSoFar: 80)?.monthly)
        // (30.85 + 109) / 80 * 100 * 30.44/7 = 760.2
        #expect(abs((monthly ?? 0) - 760.2) < 1.0)
        #expect((monthly ?? 0) / 100 > 7)   // a multiple, not "estimating"
    }

    @Test func testMissingTodayMakesThePricedTotalALowerBound() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let yesterday = formatter.string(from: Date().addingTimeInterval(-86_400))
        let stale = CodexServerUsage.Snapshot(fetchedAt: Date(), days: [
            CodexServerUsage.Day(date: yesterday, local: .zero, cloud: .zero, other: .zero),
        ])
        #expect(stale.isMissingToday)
        let fresh = CodexServerUsage.Snapshot(fetchedAt: Date(), days: [
            CodexServerUsage.Day(date: formatter.string(from: Date()), local: .zero, cloud: .zero, other: .zero),
        ])
        #expect(!fresh.isMissingToday)
    }

    @Test func testSourceLineTokenShareIsWindowScoped() {
        // Regression: the row mixed an 8-day token share with this-week quota shares.
        // Earlier windows must not dilute the current week's figure.
        let snapshot = CodexServerUsage.Snapshot(fetchedAt: Date(), days: [
            CodexServerUsage.Day(date: "2026-10-01",
                                 local: .init(uncached: 0, cached: 900_000_000, output: 0),
                                 cloud: .zero, other: .zero),
            CodexServerUsage.Day(date: "2026-10-08",
                                 local: .init(uncached: 0, cached: 100_000_000, output: 0),
                                 cloud: .init(uncached: 0, cached: 300_000_000, output: 0),
                                 other: .zero),
        ], conversations: [], cloudQuotaPct: nil)
        let start = ISO8601DateFormatter().date(from: "2026-10-07T11:30:58+08:00")
        // Whole fetched range: 300M / 1300M.
        #expect(abs((snapshot.cloudTokenShare() ?? 0) - 0.2308) < 0.001)
        // Current window only: 300M / 400M.
        #expect(abs((snapshot.cloudTokenShare(windowStart: start) ?? 0) - 0.75) < 0.001)
        let line = try? #require(snapshot.sourceLine(usedPercent: 80, windowStart: start))
        #expect(line?.contains("cloud 75% tok") == true)
    }
}
