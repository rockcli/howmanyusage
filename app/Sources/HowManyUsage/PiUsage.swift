import Foundation

/// Aggregate today's DeepSeek usage from local session logs:
/// - **pi**: `~/.pi/agent/sessions` — each response records provider/usage/tokens and cost.
///   Cost is exact, priced in USD by pi's table (converted to CNY for display).
/// - **dsh** (DeepSeek Harness): `~/.dsh/sessions/**/session.jsonl.zstd` — zstd-compressed
///   JSONL; usage records carry exact tokens but no cost, so dsh cost is estimated from the
///   model's per-token price (see `modelPrices`, sourced from pi's model store).
/// "Today" = UTC+8 day.
enum PiUsage {
    /// USD→CNY for DeepSeek display (pi logs are priced in USD).
    private static let usdToCny = 7.2
    /// DeepSeek API per-1M-token prices in USD, keyed by model. Used to estimate dsh
    /// cost, which the harness logs don't record. Unknown models fall back to the
    /// default deepseek-v4-flash price.
    private static let modelPrices: [String: (input: Double, output: Double, cacheRead: Double)] = [
        "deepseek-v4-flash": (0.14, 0.28, 0.0028),
        "deepseek-v4-pro": (0.435, 0.87, 0.003625),
    ]

    static func todayDeepSeek(
        home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()
    ) -> DailyUsage {
        // CST (UTC+8) day boundary, consistent with the rest of the app.
        var cst = Calendar(identifier: .gregorian)
        cst.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let startOfToday = cst.startOfDay(for: now)
        // Only scan files touched today or yesterday (sessions may span days); filter lines by timestamp
        let cutoff = startOfToday.addingTimeInterval(-86_400)

        let pi = scanPi(home: home, startOfToday: startOfToday, cutoff: cutoff, now: now)
        let dsh = scanDsh(home: home, startOfToday: startOfToday, cutoff: cutoff, now: now)

        return DailyUsage(
            inputTokens: UsageNumbers.sum(pi.input, dsh.input),
            outputTokens: UsageNumbers.sum(pi.output, dsh.output),
            totalTokens: UsageNumbers.sum(pi.total, dsh.total),
            cost: (pi.costUSD + dsh.costUSD) * usdToCny,
            currency: "CNY"
        )
    }

    /// Sum observed balance drops. A positive jump is a recharge or grant, so
    /// the sum remains a lower bound when spending occurred between snapshots.
    static func balanceSpend(_ balances: [Double]) -> (cost: Double, rechargeObserved: Bool)? {
        guard let first = balances.first, first.isFinite, first >= 0 else { return nil }
        var previous = first
        var spent = 0.0
        var recharge = false
        for balance in balances.dropFirst() where balance.isFinite && balance >= 0 {
            if balance > previous { recharge = true }
            else { spent += previous - balance }
            previous = balance
        }
        return (spent, recharge)
    }

    struct WalletSpend {
        var cost = 0.0
        var rechargeObserved = false
        var incomplete = false
    }

    /// Assign only intervals wholly inside the requested CST day. Polling observes
    /// net balance changes, so recharge+spend in one interval can still be hidden.
    static func walletSpend(samples: [(ts: Date, balance: Double)], start: Date, end: Date) -> WalletSpend? {
        let valid = samples.filter { $0.balance.isFinite && $0.balance >= 0 && $0.ts <= end }
            .sorted { $0.ts < $1.ts }
        let inside = valid.filter { $0.ts >= start }
        guard let first = inside.first else { return nil }
        var result = WalletSpend(incomplete: first.ts > start)
        var previous = first
        for current in inside.dropFirst() {
            guard current.ts > previous.ts else { continue }
            if current.ts.timeIntervalSince(previous.ts) > 600 { result.incomplete = true }
            if current.balance > previous.balance {
                result.rechargeObserved = true
                result.incomplete = true
            } else {
                result.cost += previous.balance - current.balance
            }
            previous = current
        }
        return result
    }

    static func todayCostFromBalance(current: Double, now: Date = Date()) -> WalletSpend? {
        var cst = Calendar(identifier: .gregorian)
        cst.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let history = StateStore.history().compactMap { row -> (ts: Date, balance: Double)? in
            row.dsBalance.map { (row.ts, $0) }
        }
        return walletSpend(samples: history + [(now, current)], start: cst.startOfDay(for: now), end: now)
    }

    private static let colabLogLock = NSLock()
    private static var cachedColabLog: (mtime: Date, size: Int, samples: [(ts: Date, balance: Double)])?

    /// Parse historical `ccu-info` balance responses logged by `colab` CLI in `~/.config/colab-cli/colab.log`.
    static func colabLogSamples(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [(ts: Date, balance: Double)] {
        let logURL = home.appendingPathComponent(".config/colab-cli/colab.log")
        let values = try? logURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = values?.contentModificationDate ?? .distantPast
        let size = values?.fileSize ?? 0

        colabLogLock.lock()
        if let cached = cachedColabLog, cached.mtime == mtime, cached.size == size {
            colabLogLock.unlock()
            return cached.samples
        }
        colabLogLock.unlock()

        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"

        var samples: [(ts: Date, balance: Double)] = []
        var pendingTimestamp: Date?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.contains("Response Body:") {
                let prefix = String(line.prefix(23))
                pendingTimestamp = df.date(from: prefix)
            } else if let ts = pendingTimestamp, line.contains("\"currentBalance\"") {
                if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   let bal = (obj["currentBalance"] as? NSNumber)?.doubleValue {
                    samples.append((ts, bal))
                }
                pendingTimestamp = nil
            }
        }

        colabLogLock.lock()
        cachedColabLog = (mtime, size, samples)
        colabLogLock.unlock()
        return samples
    }

    static func allColabSamples(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [(ts: Date, balance: Double)] {
        let fromState = StateStore.history().compactMap { row -> (ts: Date, balance: Double)? in
            row.colabBalance.map { (row.ts, $0) }
        }
        let fromLog = colabLogSamples(home: home)
        return (fromLog + fromState).sorted { $0.ts < $1.ts }
    }

    static func todayColabFromBalance(
        current: Double,
        now: Date = Date(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> WalletSpend? {
        var cst = Calendar(identifier: .gregorian)
        cst.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let history = allColabSamples(home: home)
        return walletSpend(samples: history + [(now, current)], start: cst.startOfDay(for: now), end: now)
    }

    private struct CachedFileUsage {
        let modified: Date
        let size: Int
        let entries: [(ts: Date, input: Int, output: Int, total: Int, costUSD: Double)]
    }
    private static let piCacheLock = NSLock()
    private static var piFileCache: [String: CachedFileUsage] = [:]
    private static let dshCacheLock = NSLock()
    private static var dshFileCache: [String: CachedFileUsage] = [:]

    /// pi: ~/.pi/agent/sessions/<project>/<ts>_<id>.jsonl
    /// Usage lines: message.provider == "deepseek", usage.totalTokens / input / output,
    /// usage.cost.total (USD).
    private static func scanPi(home: URL, startOfToday: Date, cutoff: Date, now: Date) -> (input: Int, output: Int, total: Int, costUSD: Double) {
        let sessionsDir = home.appendingPathComponent(".pi/agent/sessions")
        var input = 0
        var output = 0
        var total = 0
        var costUSD: Double = 0

        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil, options: []
        ) else {
            return (0, 0, 0, 0)
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()

        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: []
            ) else { continue }
            for file in files {
                guard
                    let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                    let mtime = values.contentModificationDate,
                    let size = values.fileSize,
                    mtime >= cutoff
                else { continue }

                piCacheLock.lock()
                let cached = piFileCache[file.path]
                piCacheLock.unlock()

                let entries: [(ts: Date, input: Int, output: Int, total: Int, costUSD: Double)]
                if let cached, cached.modified == mtime && cached.size == size {
                    entries = cached.entries
                } else {
                    var parsed: [(ts: Date, input: Int, output: Int, total: Int, costUSD: Double)] = []
                    LocalJSONL.read(file) { _, obj in
                        guard
                            let timestamp = obj["timestamp"] as? String,
                            let date = fractional.date(from: timestamp) ?? plain.date(from: timestamp),
                            let message = obj["message"] as? [String: Any],
                            (message["provider"] as? String) == "deepseek",
                            let usage = message["usage"] as? [String: Any]
                        else { return }
                        var cost = 0.0
                        if let costObj = usage["cost"] as? [String: Any],
                           let c = UsageNumbers.finite(costObj["total"]), c >= 0 {
                            cost = c
                        }
                        parsed.append((
                            ts: date,
                            input: UsageNumbers.count(usage["input"]),
                            output: UsageNumbers.count(usage["output"]),
                            total: UsageNumbers.count(usage["totalTokens"]),
                            costUSD: cost
                        ))
                    }
                    entries = parsed
                    piCacheLock.lock()
                    piFileCache[file.path] = CachedFileUsage(modified: mtime, size: size, entries: entries)
                    piCacheLock.unlock()
                }

                for entry in entries where entry.ts >= startOfToday && entry.ts <= now {
                    total = UsageNumbers.sum(total, entry.total)
                    input = UsageNumbers.sum(input, entry.input)
                    output = UsageNumbers.sum(output, entry.output)
                    if (costUSD + entry.costUSD).isFinite {
                        costUSD += entry.costUSD
                    }
                }
            }
        }
        return (input, output, total, costUSD)
    }

    /// DSH v1/v3/v4 may carry the same usage in a stream chunk and a final
    /// assistant message. Count one completed usage per turn/step, independently
    /// of whether the transcript has the timestamps needed for a speed estimate.
    private static func dshEntries(_ text: String) -> [(ts: Date, input: Int, output: Int, total: Int, costUSD: Double)] {
        struct Step {
            let input: Int
            let output: Int
            let cached: Int
            let total: Int
            let model: String
            let ts: Date
        }
        var model: String? = "deepseek-v4-flash" // Legacy DSH default, before request/header existed.
        var steps: [String: Step] = [:]
        var unindexed: [Step] = []
        for line in text.split(separator: "\n") {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = row["type"] as? String, let data = row["data"] as? [String: Any] else { continue }
            if type == "request/context", let name = data["model"] as? String {
                let provider = data["provider"] as? String ?? ""
                model = (name + provider).lowercased().contains("deepseek") ? name : nil
            }
            if type == "request/header", let header = data["header"] as? [String: Any],
               let config = header["config"] as? [String: Any], let name = config["model"] as? String {
                model = name.lowercased().contains("deepseek") ? name : nil
            }
            let usage: [String: Any]?
            if type == "assistant/message" { usage = data["usage"] as? [String: Any] }
            else if type == "assistant/chunk", let chunk = data["chunk"] as? [String: Any],
                    chunk["type"] as? String == "usage" { usage = chunk["usage"] as? [String: Any] }
            else { continue }
            guard let usage, let model, let ms = UsageNumbers.finite(row["time"]),
                  let timestamp = UsageNumbers.date(epoch: ms / 1000) else { continue }
            let input = UsageNumbers.count(usage["inputTokens"])
            let output = UsageNumbers.count(usage["outputTokens"])
            let cached = UsageNumbers.count(usage["cacheReadTokens"])
            let total = max(UsageNumbers.sum(input, output, cached), UsageNumbers.count(usage["totalTokens"]))
            let step = Step(input: input, output: output, cached: cached, total: total, model: model, ts: timestamp)
            if let turn = UsageNumbers.integer(data["turn"]), let index = UsageNumbers.integer(data["step"]) {
                let key = "\(turn):\(index)"
                // Deduplicate turn:step across the full session first (keeping the first
                // peak timestamp, matching UsageHistoryScanner) before filtering by day.
                if total > (steps[key]?.total ?? -1) { steps[key] = step }
            } else if type == "assistant/chunk" {
                unindexed.append(step) // Legacy logs have one usage chunk per request.
            }
        }
        return (Array(steps.values) + unindexed).map { step in
            let price = modelPrices[step.model] ?? modelPrices["deepseek-v4-flash"]!
            let cost = (Double(step.input) * price.input + Double(step.output) * price.output
                + Double(step.cached) * price.cacheRead) / 1e6
            return (ts: step.ts, input: step.input, output: step.output, total: step.total, costUSD: cost)
        }
    }

    static func dshUsage(_ text: String, start: Date, end: Date) -> (input: Int, output: Int, total: Int, costUSD: Double) {
        var result = (input: 0, output: 0, total: 0, costUSD: 0.0)
        for step in dshEntries(text) where step.ts >= start && step.ts <= end {
            result.input = UsageNumbers.sum(result.input, step.input)
            result.output = UsageNumbers.sum(result.output, step.output)
            result.total = UsageNumbers.sum(result.total, step.total)
            result.costUSD += step.costUSD
        }
        return result
    }

    private static func scanDsh(home: URL, startOfToday: Date, cutoff: Date, now: Date) -> (input: Int, output: Int, total: Int, costUSD: Double) {
        let base = home.appendingPathComponent(".dsh/sessions")
        guard let files = FileManager.default.enumerator(at: base,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            return (0, 0, 0, 0)
        }
        let versions = ["session.jsonl.zstd": 1, "session.v3.jsonl.zstd": 3, "session.v4.jsonl.zstd": 4]
        var selected: [String: (url: URL, version: Int, modified: Date, size: Int)] = [:]
        for case let file as URL in files {
            guard let version = versions[file.lastPathComponent],
                  let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate,
                  let size = values.fileSize,
                  modified >= cutoff else { continue }
            let key = file.deletingLastPathComponent().path
            if version > (selected[key]?.version ?? 0) { selected[key] = (file, version, modified, size) }
        }
        var result = (input: 0, output: 0, total: 0, costUSD: 0.0)
        for file in selected.values {
            dshCacheLock.lock()
            let cached = dshFileCache[file.url.path]
            dshCacheLock.unlock()

            let entries: [(ts: Date, input: Int, output: Int, total: Int, costUSD: Double)]
            if let cached, cached.modified == file.modified && cached.size == file.size {
                entries = cached.entries
            } else {
                guard let text = Zstd.decompress(file.url) else { continue }
                entries = dshEntries(text)
                dshCacheLock.lock()
                dshFileCache[file.url.path] = CachedFileUsage(modified: file.modified, size: file.size, entries: entries)
                dshCacheLock.unlock()
            }

            for step in entries where step.ts >= startOfToday && step.ts <= now {
                result.input = UsageNumbers.sum(result.input, step.input)
                result.output = UsageNumbers.sum(result.output, step.output)
                result.total = UsageNumbers.sum(result.total, step.total)
                result.costUSD += step.costUSD
            }
        }
        return result
    }
}

/// Aggregate Antigravity usage across CLI (`~/.gemini/antigravity-cli/brain`) and
/// Desktop clients (`~/.gemini/antigravity/brain`, `~/.gemini/antigravity-ide/brain`).
enum AntigravityUsage {
    struct Summary: Sendable {
        var plan: String?
        var today: DailyUsage
        var fiveHourTokens = 0
        var fiveHourCostUSD = 0.0
        var weeklyTokens = 0
        var weeklyCostUSD = 0.0
        var weekDailyTokens: [Double] = Array(repeating: 0, count: 7)
        var cliTokens = 0
        var clientTokens = 0

        var monthlyCostUSD: Double { weeklyCostUSD * 30.44 / 7.0 }
    }

    private static let cacheLock = NSLock()
    private static var cachedSummary: (summary: Summary, at: Date, homePath: String)?

    static func summary(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date(),
        useCache: Bool = true
    ) -> Summary {
        if useCache {
            cacheLock.lock()
            if let c = cachedSummary, c.homePath == home.path, abs(now.timeIntervalSince(c.at)) < 15 {
                let s = c.summary
                cacheLock.unlock()
                return s
            }
            cacheLock.unlock()
        }

        var cst = Calendar(identifier: .gregorian)
        cst.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let todayStart = cst.startOfDay(for: now)
        let weekStart = cst.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        let tomorrowStart = cst.date(byAdding: .day, value: 1, to: todayStart) ?? now
        let fiveHourStart = now.addingTimeInterval(-5 * 3600)

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()

        let files = UsageHistoryScanner.antigravityTranscriptFiles(home: home, modifiedSince: weekStart)

        var todayInput = 0
        var todayOutput = 0
        var todayTotal = 0
        var todayCost = 0.0
        var fiveHourTokens = 0
        var fiveHourCost = 0.0
        var weeklyTokens = 0
        var weeklyCost = 0.0
        var weekDaily = [Double](repeating: 0, count: 7)
        var cliTokens = 0
        var clientTokens = 0
        var latestModel: (name: String, ts: Date)?

        struct StepRecord {
            let ts: Date
            let model: String?
            let input: Int
            let cacheRead: Int
            let cacheWrite: Int
            let output: Int
            var total: Int { UsageNumbers.sum(input, cacheRead, cacheWrite, output) }
        }

        for file in files {
            let isCLI = file.path.contains("/.gemini/antigravity-cli/")
            var byStep: [Int: StepRecord] = [:]
            var unindexed: [StepRecord] = []

            LocalJSONL.read(file, matching: { $0.contains("PLANNER_RESPONSE") }) { _, obj in
                guard
                      obj["type"] as? String == "PLANNER_RESPONSE",
                      let created = obj["created_at"] as? String,
                      let ts = fractional.date(from: created) ?? plain.date(from: created),
                      ts >= weekStart, ts <= tomorrowStart
                else { return }

                let inp = UsageNumbers.count(obj["input_tokens"])
                let cr = UsageNumbers.count(obj["cache_read_tokens"])
                let cw = UsageNumbers.count(obj["cache_write_tokens"])
                let out = UsageNumbers.count(obj["output_tokens"])
                let model = obj["model"] as? String
                if let model, !model.isEmpty, latestModel == nil || ts >= latestModel!.ts {
                    latestModel = (model, ts)
                }
                let rec = StepRecord(ts: ts, model: model, input: inp, cacheRead: cr, cacheWrite: cw, output: out)
                guard rec.total > 0 else { return }
                if let step = (obj["step_index"] as? NSNumber)?.intValue {
                    if rec.total >= (byStep[step]?.total ?? 0) {
                        byStep[step] = rec
                    }
                } else {
                    unindexed.append(rec)
                }
            }

            for rec in Array(byStep.values) + unindexed {
                let cost = AntigravityValue.cost(
                    model: rec.model, input: rec.input, cacheRead: rec.cacheRead,
                    cacheWrite: rec.cacheWrite, output: rec.output
                )
                weeklyTokens = UsageNumbers.sum(weeklyTokens, rec.total)
                weeklyCost += cost
                if isCLI {
                    cliTokens = UsageNumbers.sum(cliTokens, rec.total)
                } else {
                    clientTokens = UsageNumbers.sum(clientTokens, rec.total)
                }
                let dayIdx = cst.dateComponents([.day], from: weekStart, to: cst.startOfDay(for: rec.ts)).day ?? -1
                if (0..<7).contains(dayIdx) {
                    weekDaily[dayIdx] += Double(rec.total)
                }
                if rec.ts >= fiveHourStart {
                    fiveHourTokens = UsageNumbers.sum(fiveHourTokens, rec.total)
                    fiveHourCost += cost
                }
                if rec.ts >= todayStart {
                    todayInput = UsageNumbers.sum(todayInput, rec.input, rec.cacheRead, rec.cacheWrite)
                    todayOutput = UsageNumbers.sum(todayOutput, rec.output)
                    todayTotal = UsageNumbers.sum(todayTotal, rec.total)
                    todayCost += cost
                }
            }
        }

        let today = DailyUsage(
            inputTokens: todayInput,
            outputTokens: todayOutput,
            totalTokens: todayTotal,
            cost: todayCost,
            currency: "USD",
            costIsEstimated: true
        )
        let result = Summary(
            plan: latestModel?.name,
            today: today,
            fiveHourTokens: fiveHourTokens,
            fiveHourCostUSD: fiveHourCost,
            weeklyTokens: weeklyTokens,
            weeklyCostUSD: weeklyCost,
            weekDailyTokens: weekDaily,
            cliTokens: cliTokens,
            clientTokens: clientTokens
        )
        if useCache {
            cacheLock.lock()
            cachedSummary = (result, now, home.path)
            cacheLock.unlock()
        }
        return result
    }

    /// API-equivalent USD cost and tokens from Gemini transcript steps since `since`.
    static func windowTotals(
        since: Date,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()
    ) -> (costUSD: Double, tokens: Int) {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let files = UsageHistoryScanner.antigravityTranscriptFiles(home: home, modifiedSince: since)
        var totalCost = 0.0
        var totalTokens = 0

        struct StepRecord {
            let model: String?
            let input: Int
            let cacheRead: Int
            let cacheWrite: Int
            let output: Int
            var total: Int { UsageNumbers.sum(input, cacheRead, cacheWrite, output) }
        }

        for file in files {
            var byStep: [Int: StepRecord] = [:]
            var unindexed: [StepRecord] = []
            var model: String?

            LocalJSONL.read(file, matching: { $0.contains("PLANNER_RESPONSE") || $0.contains("USER_INPUT") }) { _, obj in
                guard
                      let created = obj["created_at"] as? String,
                      let ts = fractional.date(from: created) ?? plain.date(from: created),
                      ts <= now.addingTimeInterval(60)
                else { return }

                if let selected = AntigravitySpeedScanner.extractModel(from: obj) {
                    model = selected.model
                }
                guard obj["type"] as? String == "PLANNER_RESPONSE", ts >= since else { return }
                let inp = UsageNumbers.count(obj["input_tokens"])
                let cr = UsageNumbers.count(obj["cache_read_tokens"])
                let cw = UsageNumbers.count(obj["cache_write_tokens"])
                let out = UsageNumbers.count(obj["output_tokens"])
                let rec = StepRecord(
                    model: model, input: inp, cacheRead: cr, cacheWrite: cw, output: out
                )
                guard rec.total > 0 else { return }
                if let step = (obj["step_index"] as? NSNumber)?.intValue {
                    if rec.total >= (byStep[step]?.total ?? 0) {
                        byStep[step] = rec
                    }
                } else {
                    unindexed.append(rec)
                }
            }

            for rec in Array(byStep.values) + unindexed where AntigravityValue.usesGeminiQuota(rec.model) {
                totalCost += AntigravityValue.cost(
                    model: rec.model, input: rec.input, cacheRead: rec.cacheRead,
                    cacheWrite: rec.cacheWrite, output: rec.output
                )
                totalTokens = UsageNumbers.sum(totalTokens, rec.total)
            }
        }
        return (totalCost, totalTokens)
    }

    static func windowCostUSD(
        since: Date,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()
    ) -> Double {
        windowTotals(since: since, home: home, now: now).costUSD
    }

    static func windowTokens(
        since: Date,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()
    ) -> Int {
        windowTotals(since: since, home: home, now: now).tokens
    }
}
