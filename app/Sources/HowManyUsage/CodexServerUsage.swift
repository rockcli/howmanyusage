import Foundation

/// Server-side (ChatGPT backend) usage attribution for the Codex weekly quota.
///
/// Why this exists: the local `~/.codex/sessions` rollouts only cover work that ran
/// through this Mac's Codex client. Cloud agent work (Dots / Aeon, Work) consumes the
/// same weekly quota and never appears in those rollouts, so any
/// `localCost / usedPercent` estimate is diluted — and token volume alone cannot be
/// converted into quota share, because quota is charged per model/effort, not per token.
///
/// The server exposes its own attribution; all three routes are undocumented internal
/// ones (the desktop app itself tolerates 404 and daily calculation lag):
///   * `/wham/analytics/daily-workspace-usage-counts` — per-day tokens split by client
///   * `/wham/usage/thread_usage/query_v2`            — per-conversation quota percent
///   * `/wham/usage/plan_limit_history`               — completed windows + breakdowns
///
/// Every call degrades independently: a failure leaves the corresponding field `nil`
/// and the UI must say "unknown" rather than fabricate a number.
enum CodexServerUsage {

    // MARK: - Sources

    /// Which product surface a server-reported client id belongs to.
    ///
    /// On this account the classification is verifiable: `CODEX_DESKTOP_APP` daily
    /// token totals match the local rollout volume (100.5M vs 92.6M on 2026-10-08),
    /// while `CODEX_WORK_WEB` appears only on days with zero local Codex activity.
    enum Source: String, Codable, Sendable {
        case local
        case cloud
        case other

        static func classify(clientId: String?) -> Source {
            switch (clientId ?? "").uppercased() {
            case "CODEX_DESKTOP_APP", "CODEX_SERVICE_EXEC": return .local
            case "CODEX_WORK_WEB", "CODEX_WORK_DESKTOP": return .cloud
            default: return .other
            }
        }
    }

    /// Token classes as the server reports them, kept separate so cloud work can be
    /// priced exactly instead of with a blended average.
    struct TokenCounts: Codable, Sendable, Equatable {
        var uncached = 0
        var cached = 0
        var output = 0

        var total: Int { uncached + cached + output }
        static let zero = TokenCounts()

        static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
            TokenCounts(uncached: lhs.uncached + rhs.uncached,
                        cached: lhs.cached + rhs.cached,
                        output: lhs.output + rhs.output)
        }

        /// API-equivalent USD at the given standard rates.
        func usd(using pricing: CodexValue.Pricing) -> Double {
            Double(uncached) * pricing.input
                + Double(cached) * pricing.cached
                + Double(output) * pricing.output
        }
    }

    struct Day: Codable, Sendable {
        let date: String
        let local: TokenCounts
        let cloud: TokenCounts
        let other: TokenCounts
        var total: TokenCounts { local + cloud + other }
    }

    /// One conversation as the server reports it. `weeklyPct` is the official share of
    /// the weekly quota; `hasLocalRollout` says whether this Mac has a rollout file for
    /// the same thread, which is the only reliable way to tell local from cloud here.
    struct Conversation: Codable, Sendable {
        let id: String
        let weeklyPct: Double
        let status: String
        let hasLocalRollout: Bool
    }

    struct Snapshot: Codable, Sendable {
        var fetchedAt: Date
        var days: [Day] = []
        var conversations: [Conversation] = []
        /// Σ weekly percent of conversations with no local rollout (cloud; a lower
        /// bound — conversation ids can only be harvested from local desktop logs).
        var cloudQuotaPct: Double? = nil
        /// Σ weekly percent of conversations that do have a local rollout.
        var localQuotaPct: Double? = nil
        var notes: [String] = []

        var localTokens: Int { days.reduce(0) { $0 + $1.local.total } }
        var cloudTokens: Int { days.reduce(0) { $0 + $1.cloud.total } }
        var totalTokens: Int { days.reduce(0) { $0 + $1.total.total } }

        /// Cloud (Dots/Work) usage as API-equivalent USD, priced at `pricing`.
        ///
        /// The cloud model mix is not observable from this machine (the server's per-model
        /// detail lags and the per-conversation USD route is not available on this plan),
        /// so cloud tokens are priced at the GPT-6.1 Sol standard rates, which is the
        /// basis the account owner chose for Dot work.
        static func initialWeeklyPercent(windowStart: Date?, history: [UsageSnapshot]? = nil) -> Double? {
            guard let windowStart, windowStart.timeIntervalSince1970.isFinite else { return nil }
            let samples = history ?? StateStore.history()
            return samples.first(where: {
                abs($0.ts.timeIntervalSince(windowStart)) < 1
                    && $0.codexWeekly.map { $0.isFinite && (0...100).contains($0) } == true
            })?.codexWeekly
        }

        static func observedWeeklyPercent(windowStart: Date?, usedPercent: Double?,
                                          history: [UsageSnapshot]? = nil) -> Double? {
            guard let usedPercent, usedPercent.isFinite, (0...100).contains(usedPercent) else { return nil }
            guard let initial = initialWeeklyPercent(windowStart: windowStart, history: history) else {
                return usedPercent
            }
            return max(0, usedPercent - initial)
        }

        /// Cloud (Dots/Work) usage as API-equivalent USD paired with the quota delta
        /// covered by `[windowStart, now]` so callers never divide incremental spend
        /// by cumulative pre-boundary percentage.
        func cloudValuation(windowStart: Date?, using pricing: CodexValue.Pricing, now: Date = Date(),
                            usedPercent: Double? = nil, localUSD: Double = 0,
                            history: [UsageSnapshot]? = nil) -> (cloudUSD: Double, pctSoFar: Double?)? {
            guard let windowStart, windowStart.timeIntervalSince1970.isFinite,
                  now.timeIntervalSince1970.isFinite, windowStart < now else { return nil }
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(secondsFromGMT: 0)!
            var day = utc.startOfDay(for: windowStart)
            // Apply the weekly bound before either estimation path.
            guard now.timeIntervalSince(day) <= 8 * 86400 else { return nil }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = utc.timeZone
            let rows = days.compactMap { row -> (Date, Day)? in
                guard let date = formatter.date(from: row.date), date <= now else { return nil }
                return (date, row)
            }.sorted { $0.0 < $1.0 }
            guard !rows.isEmpty else { return nil }
            let today = utc.startOfDay(for: now)
            let samples = history ?? StateStore.history()
            let initial = Self.initialWeeklyPercent(windowStart: windowStart, history: samples)
            let deltaPct = Self.observedWeeklyPercent(windowStart: windowStart, usedPercent: usedPercent, history: samples)
            let reference = Array(rows.filter { $0.0 < today }.suffix(3))
            let hasRecentCloud = reference.contains { $0.1.cloud.total > 0 }
            // When today's backend tokens are missing and recent days had cloud activity,
            // calibrate against the most recent fully observed, reset-free cloud day.
            // Skip calibration when recent days have zero cloud usage so stale prior-plan
            // days cannot invent phantom cloud spend after switching plans or stopping cloud use.
            var calibrated: Double?
            if hasRecentCloud, !rows.contains(where: { $0.0 == today }), let usedPercent,
               usedPercent.isFinite, (0...100).contains(usedPercent),
               localUSD.isFinite, localUSD >= 0,
               let initial, usedPercent >= initial,
               let rate = quotaValueRate(using: pricing, history: samples, now: now, windowStart: windowStart) {
                let estimate = rate * (usedPercent - initial) - localUSD
                if estimate.isFinite { calibrated = max(0, estimate) }
            }
            let dailyAverage = reference.isEmpty ? nil
                : reference.reduce(0.0) { $0 + $1.1.cloud.usd(using: pricing) } / Double(reference.count)
            var total = 0.0
            var observed = 0.0
            while day < now {
                let next = day.addingTimeInterval(86400)
                let overlap = min(next, now).timeIntervalSince(max(day, windowStart))
                if let row = rows.first(where: { $0.0 == day })?.1 {
                    // Completed day: prorate by the post-reset fraction. Today's row,
                    // if supplied, represents the elapsed day rather than a future full day.
                    let covered = min(86400, now.timeIntervalSince(day))
                    let cost = row.cloud.usd(using: pricing) * overlap / max(1, covered)
                    observed += cost
                    total += cost
                } else if let dailyAverage {
                    // Daily reporting lags: project only the in-window missing interval
                    // using the latest three reported days as a rate, never as actual spend.
                    total += dailyAverage * overlap / 86400
                } else {
                    return nil
                }
                day = next
            }
            // A historical model mix is only an estimate. Subtracting this
            // window's model-priced local USD must never erase reported cloud USD.
            return (calibrated.map { max(observed, $0) } ?? total, deltaPct)
        }

        func cloudUSD(windowStart: Date?, using pricing: CodexValue.Pricing, now: Date = Date(),
                      usedPercent: Double? = nil, localUSD: Double = 0, history: [UsageSnapshot]? = nil) -> Double? {
            cloudValuation(windowStart: windowStart, using: pricing, now: now,
                           usedPercent: usedPercent, localUSD: localUSD, history: history)?.cloudUSD
        }

        /// API-equivalent USD per official account quota point. Never sum thread
        /// lifetime percentages; resumed Dots chats may span reset windows.
        /// When `windowStart` is provided, restricts calibration anchors to the current
        /// window (or the immediately preceding UTC day when the window is < 24h old).
        func quotaValueRate(using pricing: CodexValue.Pricing, history: [UsageSnapshot], now: Date, windowStart: Date? = nil) -> Double? {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            let minEnd: Date? = windowStart.map { start in
                now.timeIntervalSince(start) < 86400 ? start.addingTimeInterval(-86400) : start
            }
            for day in days.sorted(by: { $0.date > $1.date }) where day.cloud.total > 0 {
                guard let start = formatter.date(from: day.date) else { continue }
                let end = start.addingTimeInterval(86400)
                guard end <= now else { continue }
                if let minEnd, end < minEnd { continue }
                let samples = history.filter { row in
                    row.ts >= start && row.ts < end
                        && row.codexWeekly.map { $0.isFinite && (0...100).contains($0) } == true
                        && row.codexWeeklyReset.flatMap(Double.init)?.isFinite == true
                }.sorted { $0.ts < $1.ts }
                guard let first = samples.first, let last = samples.last,
                      first.ts.timeIntervalSince(start) <= 600, end.timeIntervalSince(last.ts) <= 600,
                      let initial = first.codexWeekly, let final = last.codexWeekly,
                      let reset = first.codexWeeklyReset.flatMap(Double.init), final - initial >= 1 else { continue }
                var valid = true
                for (previous, current) in zip(samples, samples.dropFirst()) {
                    if current.ts.timeIntervalSince(previous.ts) > 900
                        || current.codexWeekly! < previous.codexWeekly!
                        || abs(Double(current.codexWeeklyReset!)! - reset) >= 300 { valid = false; break }
                }
                guard valid else { continue }
                let span = last.ts.timeIntervalSince(first.ts)
                let dailyQuota = (final - initial) * 86400 / span
                let rate = (day.local + day.cloud).usd(using: pricing) / dailyQuota
                if rate.isFinite, rate >= 0 { return rate }
            }
            return nil
        }

        /// Diagnostic only; valuation notes are deliberately absent from the compact UI.
        func valuationNote(windowStart: Date?) -> String {
            windowStart == nil ? "window unknown" : "cloud estimate: quota-calibrated reporting gaps; partial days prorated; daily-rate fallback projected"
        }

        func daysInWindow(_ windowStart: Date?) -> [Day] {
            guard let windowStart else { return [] }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return days.filter {
                guard let day = formatter.date(from: $0.date) else { return false }
                return day.addingTimeInterval(86400) > windowStart
            }
        }

        /// Newest day the server has reported (UTC date string).
        var latestDay: String? { days.map(\.date).max() }

        /// True when the newest server day is older than today (UTC): the backend
        /// calculates usage daily, so the current day may not be included yet. This is a
        /// *data completeness* note, not a price bound — the Sol-equivalent basis can
        /// under- or over-state the real cloud mix in either direction.
        var isMissingToday: Bool {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            let today = formatter.string(from: Date())
            return (days.map(\.date).max() ?? "") < today
        }

        /// Cloud share of tokens. Scoped to the weekly window when `windowStart` is
        /// given — the fetched range is deliberately wider than one window (8 days, so the
        /// per-day view has context), and mixing the two ranges on one row was misleading.
        func cloudTokenShare(windowStart: Date? = nil) -> Double? {
            let scoped = windowStart == nil ? days : daysInWindow(windowStart)
            let total = scoped.reduce(0) { $0 + $1.total.total }
            guard total > 0 else { return nil }
            let cloud = scoped.reduce(0) { $0 + $1.cloud.total }
            return Double(cloud) / Double(total)
        }

        /// Share of the official used percentage attributable to cloud conversations.
        /// nil when the server attribution is unavailable (then: unknown, not zero).
        func cloudQuotaShare(usedPercent: Double?) -> Double? {
            guard let usedPercent, usedPercent > 0, let cloud = cloudQuotaPct else { return nil }
            return min(1, max(0, cloud / usedPercent))
        }

        /// A window whose quota is materially consumed elsewhere cannot be used to
        /// calibrate the local dollar-per-percent rate; the last undiluted anchor is
        /// kept instead. 15% matches the community reference implementation's bar for
        /// treating a segment as contaminated.
        static let dilutionThreshold = 0.15

        /// Any evidence that part of this window's quota went somewhere this machine
        /// cannot price. Conversation attribution is the primary signal; the cloud token
        /// share is only a *fallback flag* — token share is never used to apportion quota
        /// (different models/efforts are charged differently per token).
        func dilutionEvidence(usedPercent: Double?, windowStart: Date? = nil) -> Double {
            max(cloudQuotaShare(usedPercent: usedPercent) ?? 0,
                cloudTokenShare(windowStart: windowStart) ?? 0)
        }

        func isDiluted(usedPercent: Double?, windowStart: Date? = nil) -> Bool {
            dilutionEvidence(usedPercent: usedPercent, windowStart: windowStart) >= Snapshot.dilutionThreshold
        }
    }

    /// Pairs in-window local + cloud USD against only the quota percentage consumed
    /// since `windowStart`, excluding pre-observation consumption symmetrically.
    static func codexExtrapolatedValue(
        serverUsage: Snapshot?, windowStart: Date?, usedPercent: Double?, localUSD: Double,
        using pricing: CodexValue.Pricing = CodexValue.cloudPricing,
        now: Date = Date(), history: [UsageSnapshot]? = nil
    ) -> (cloudUSD: Double?, pctSoFar: Double, weekly: Double?, monthly: Double?) {
        let samples = history ?? StateStore.history()
        let valuation = serverUsage?.cloudValuation(
            windowStart: windowStart, using: pricing, now: now,
            usedPercent: usedPercent, localUSD: localUSD, history: samples
        )
        let pctSoFar = valuation?.pctSoFar
            ?? Snapshot.observedWeeklyPercent(windowStart: windowStart, usedPercent: usedPercent, history: samples)
            ?? 0
        let extrapolated = CodexValue.extrapolate(
            costSoFar: localUSD + (valuation?.cloudUSD ?? 0),
            pctSoFar: pctSoFar
        )
        return (valuation?.cloudUSD, pctSoFar, extrapolated?.weekly, extrapolated?.monthly)
    }

    // MARK: - Endpoints

    static let dailyCountsURL = "https://chatgpt.com/backend-api/wham/analytics/daily-workspace-usage-counts"
    static let threadUsageURL = "https://chatgpt.com/backend-api/wham/usage/thread_usage/query_v2"
    static let planHistoryURL = "https://chatgpt.com/backend-api/wham/usage/plan_limit_history"

    /// Batches larger than this are rejected by the server ("List should have at most
    /// 100 items"), so conversations are queried in chunks.
    static let maxThreadsPerRequest = 100

    // MARK: - Fetch

    /// Best-effort snapshot. Returns nil only when the daily token split itself is
    /// unavailable — without it there is nothing trustworthy to show.
    ///
    /// `windowStart` scopes the per-conversation attribution: `weekly_limit_percent` is
    /// relative to the weekly window a conversation ran in, so summing conversations
    /// across windows over-counts badly (observed: 115% of a single window).
    static func fetch(days: Int = 8, windowStart: Date? = nil, timeout: Double = 20) async -> Snapshot? {
        guard let auth = try? Auth.codex() else { return nil }
        var headers = [
            "Authorization": "Bearer \(auth.accessToken)",
            "User-Agent": "codex-cli",
            "Accept": "application/json",
        ]
        if let accountId = auth.accountId { headers["ChatGPT-Account-Id"] = accountId }

        guard let dayRows = try? await dailyCounts(days: days, headers: headers, timeout: timeout) else {
            return nil
        }
        var snapshot = Snapshot(fetchedAt: Date(), days: dayRows)

        let ids = harvestConversationIDs(since: Date().addingTimeInterval(-Double(days + 1) * 86_400))
        guard !ids.isEmpty else {
            snapshot.notes.append("no conversation ids found in desktop logs")
            return snapshot
        }
        let localIDs = localRolloutThreadIDs()
        guard let rows = try? await threadUsage(ids: ids, headers: headers, timeout: timeout) else {
            snapshot.notes.append("thread usage query failed")
            return snapshot
        }
        let attributed = attribute(rows: rows, localIDs: localIDs, windowStart: windowStart)
        snapshot.conversations = attributed.conversations
        snapshot.cloudQuotaPct = attributed.cloudPct
        snapshot.localQuotaPct = attributed.localPct
        if attributed.excluded > 0 {
            snapshot.notes.append("\(attributed.excluded) conversations outside this window excluded")
        }
        if snapshot.conversations.contains(where: { $0.status == "partial" }) {
            snapshot.notes.append("conversation attribution is partial (quota shares are lower bounds)")
        }
        return snapshot
    }

    /// Split conversations into the current window's cloud/local quota shares.
    ///
    /// The local/cloud discriminator is whether this Mac has a rollout file for the same
    /// thread; the window filter uses the UUIDv7 creation timestamp carried by Codex
    /// thread ids.
    static func attribute(
        rows: [ThreadRow], localIDs: Set<String>, windowStart: Date?
    ) -> (conversations: [Conversation], cloudPct: Double?, localPct: Double?, excluded: Int) {
        guard let windowStart else { return ([], nil, nil, rows.count) }
        var conversations: [Conversation] = []
        var excluded = 0
        for row in rows {
            do {
                guard let created = creationDate(threadID: row.id), created >= windowStart else {
                    excluded += 1
                    continue
                }
            }
            conversations.append(Conversation(id: row.id, weeklyPct: row.pct, status: row.status,
                                              hasLocalRollout: localIDs.contains(row.id)))
        }
        let cloud = conversations.filter { !$0.hasLocalRollout && $0.weeklyPct > 0 }
        let local = conversations.filter { $0.hasLocalRollout && $0.weeklyPct > 0 }
        return (conversations,
                cloud.isEmpty ? nil : cloud.reduce(0) { $0 + $1.weeklyPct },
                local.isEmpty ? nil : local.reduce(0) { $0 + $1.weeklyPct },
                excluded)
    }

    /// Codex thread ids are UUIDv7: the first 48 bits are a millisecond timestamp.
    static func creationDate(threadID: String) -> Date? {
        let hex = Array(threadID.replacingOccurrences(of: "-", with: ""))
        guard hex.count == 32, hex[12] == "7",
              let millis = UInt64(String(hex[0..<12]), radix: 16) else { return nil }
        return Date(timeIntervalSince1970: Double(millis) / 1000)
    }

    /// `daily-workspace-usage-counts` → per-day token totals per client.
    /// Recent days carry token counts before the turn/thread counters fill in, which is
    /// exactly the window we care about.
    static func dailyCounts(days: Int, headers: [String: String], timeout: Double) async throws -> [Day] {
        let end = Date()
        let start = end.addingTimeInterval(-Double(days) * 86_400)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let url = "\(dailyCountsURL)?start_date=\(formatter.string(from: start))"
            + "&end_date=\(formatter.string(from: end))&group_by=day"
        return try parseDailyCounts(await request(url, headers: headers, timeout: timeout))
    }

    /// Pure parser (unit-tested; the network path above is a thin wrapper).
    static func parseDailyCounts(_ data: Data) throws -> [Day] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexServerUsageError("daily counts: response is not JSON")
        }
        let rows = object["data"] as? [[String: Any]] ?? []
        var responseTokens = 0
        return try rows.compactMap { row in
            guard let date = row["date"] as? String else { return nil }
            var local = TokenCounts.zero, cloud = TokenCounts.zero, other = TokenCounts.zero
            for client in row["clients"] as? [[String: Any]] ?? [] {
                let counts = TokenCounts(uncached: try int(client["uncached_text_input_tokens"]),
                                         cached: try int(client["cached_text_input_tokens"]),
                                         output: try int(client["text_output_tokens"]))
                // Every later token subtotal is a subset of this nonnegative
                // response total. Reject overflow before using unchecked sums.
                for count in [counts.uncached, counts.cached, counts.output] {
                    let (sum, overflow) = responseTokens.addingReportingOverflow(count)
                    guard !overflow else { throw CodexServerUsageError("daily counts: token total overflow") }
                    responseTokens = sum
                }
                switch Source.classify(clientId: client["client_id"] as? String) {
                case .local: local = local + counts
                case .cloud: cloud = cloud + counts
                case .other: other = other + counts
                }
            }
            return Day(date: date, local: local, cloud: cloud, other: other)
        }
    }

    struct ThreadRow: Sendable {
        let id: String
        let pct: Double
        let status: String
    }

    /// `thread_usage/query_v2` → official weekly percentage per conversation.
    /// Local CLI threads answer `data_status: unavailable` with a zero share, which is
    /// how the server itself separates "tracked conversation" from "local rollout only".
    static func threadUsage(ids: [String], headers: [String: String], timeout: Double) async throws -> [ThreadRow] {
        var rows: [ThreadRow] = []
        for chunk in stride(from: 0, to: ids.count, by: maxThreadsPerRequest).map({ Array(ids[$0..<min($0 + maxThreadsPerRequest, ids.count)]) }) {
            let body: [String: Any] = ["threads": chunk.map { ["thread_id": $0] }]
            let data = try await request(threadUsageURL, method: "POST", body: body, headers: headers, timeout: timeout)
            rows.append(contentsOf: try parseThreadUsage(data))
        }
        return rows
    }

    /// Pure parser (unit-tested).
    static func parseThreadUsage(_ data: Data) throws -> [ThreadRow] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexServerUsageError("thread usage: response is not JSON")
        }
        return try (object["threads"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["thread_id"] as? String else { return nil }
            let pct: Double
            if let raw = row["weekly_limit_percent"], !(raw is NSNull) {
                guard let value = double(raw), (0...100).contains(value) else {
                    throw CodexServerUsageError("thread usage: invalid weekly percentage")
                }
                pct = value
            } else { pct = 0 }
            return ThreadRow(id: id,
                             pct: pct,
                             status: row["data_status"] as? String ?? "unknown")
        }
    }

    // MARK: - Local id harvesting

    /// Cloud conversations never appear in a server-side list (`wham/tasks/list` is empty
    /// when nothing is queued), so ids come from the desktop app's own logs. Every
    /// `conversationId=` is collected — local *and* cloud — and the local/cloud split is
    /// decided afterwards by whether this Mac has a rollout file for the same thread.
    /// That matters: some cloud conversations are only referenced by resume/notification
    /// lines, so filtering log lines up front would under-count them.
    ///
    /// The logs are chatty (~60 MB/day), so candidates are read newest-first under a
    /// byte budget and decoded lossily — a single invalid byte must not hide an id.
    static func harvestConversationIDs(since: Date, logsRoot: URL? = nil) -> [String] {
        let root = logsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/com.openai.codex")
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: [(url: URL, modified: Date, size: Int)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate, modified >= since,
                  let size = values.fileSize, size > 0 else { continue }
            candidates.append((url, modified, size))
        }
        candidates.sort { $0.modified > $1.modified }

        var ids = Set<String>()
        var budget = 150 * 1024 * 1024
        for candidate in candidates {
            guard budget > 0 else { break }
            budget -= candidate.size
            guard let data = try? Data(contentsOf: candidate.url, options: .mappedIfSafe) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n") where line.contains("conversationId=") {
                if let id = uuid(after: "conversationId=", in: line) { ids.insert(id) }
            }
        }
        return Array(ids)
    }

    /// Thread ids that this Mac has a rollout file for (the local/cloud discriminator).
    static func localRolloutThreadIDs(home: URL? = nil) -> Set<String> {
        let base = home ?? FileManager.default.homeDirectoryForCurrentUser
        var ids = Set<String>()
        for sub in [".codex/sessions", ".codex/archived_sessions"] {
            let root = base.appendingPathComponent(sub)
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                for id in uuids(in: url.lastPathComponent) { ids.insert(id) }
            }
        }
        return ids
    }

    // MARK: - Small helpers

    static func uuid(after marker: String, in line: Substring) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        let tail = line[range.upperBound...]
        guard tail.count >= 36 else { return nil }
        let candidate = String(tail.prefix(36))
        return isUUID(candidate) ? candidate : nil
    }

    static func uuids(in text: String) -> [String] {
        var found: [String] = []
        let chars = Array(text)
        guard chars.count >= 36 else { return [] }
        var index = 0
        while index + 36 <= chars.count {
            let candidate = String(chars[index..<(index + 36)])
            if isUUID(candidate) {
                found.append(candidate)
                index += 36
            } else {
                index += 1
            }
        }
        return found
    }

    static func isUUID(_ text: String) -> Bool {
        guard text.count == 36 else { return false }
        for (offset, char) in text.enumerated() {
            let isDash = (offset == 8 || offset == 13 || offset == 18 || offset == 23)
            if isDash {
                if char != "-" { return false }
            } else if !char.isHexDigit {
                return false
            }
        }
        return true
    }

    private static func int(_ value: Any?) throws -> Int {
        guard let value, !(value is NSNull) else { return 0 }
        guard let count = UsageNumbers.integer(value), count >= 0 else {
            throw CodexServerUsageError("daily counts: invalid token count")
        }
        return count
    }

    private static func double(_ value: Any?) -> Double? {
        UsageNumbers.finite(value)
    }

    private static func envProxy() -> [String: Any]? {
        let env = ProcessInfo.processInfo.environment
        let raw = env["https_proxy"] ?? env["HTTPS_PROXY"] ?? env["http_proxy"] ?? env["HTTP_PROXY"]
        guard let raw, !raw.isEmpty, let url = URL(string: raw), let host = url.host else { return nil }
        let port = url.port ?? 80
        return ["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
                "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port]
    }

    private static let apiSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        if let proxy = envProxy() { config.connectionProxyDictionary = proxy }
        return URLSession(configuration: config)
    }()

    private static func request(
        _ urlString: String, method: String = "GET", body: [String: Any]? = nil,
        headers: [String: String], timeout: Double
    ) async throws -> Data {
        guard let url = URL(string: urlString) else { throw CodexServerUsageError("Invalid URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await apiSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CodexServerUsageError("HTTP \(code)")
        }
        return data
    }
}

struct CodexServerUsageError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// Display helpers shared by the menu and the text report.
extension CodexServerUsage.Snapshot {
    /// The cloud quota share is a lower bound because ids are harvested locally.
    ///
    /// Units matter here and are deliberately spelled out: `% of tokens` and `% of quota`
    /// are different denominators and must never be added together.
    func cloudQuotaText(usedPercent: Double?) -> String? {
        guard let cloud = cloudQuotaPct else { return nil }
        return String(format: "cloud chats %.0f%% of quota", cloud)
    }

    /// Quota percentage the server attribution does not account for. This is *not* all
    /// "unknown": conversations the server does not track (local CLI subagent turns
    /// answer `data_status: unavailable`) land here too.
    func unattributedQuotaPct(usedPercent: Double?) -> Double? {
        guard let usedPercent, let cloud = cloudQuotaPct else { return nil }
        return max(0, usedPercent - cloud - (localQuotaPct ?? 0))
    }

    /// One-line source summary: cloud token share, cloud quota share, unattributed part.
    func sourceLine(usedPercent: Double?, windowStart: Date? = nil) -> String? {
        var parts: [String] = []
        if let share = cloudTokenShare(windowStart: windowStart) {
            parts.append(String(format: "cloud %.0f%% tok", share * 100))
        }
        if let cloud = cloudQuotaPct {
            parts.append(String(format: "cloud chats %.0f%% of quota", cloud))
        }
        if let unattributed = unattributedQuotaPct(usedPercent: usedPercent) {
            parts.append(String(format: "unattributed %.0f%% of quota", unattributed))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }
}
