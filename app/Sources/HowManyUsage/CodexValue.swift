import Foundation

private struct PlanDescriptor {
    let name: String
    let monthlyPriceUSD: Double?
}

private func normalizedPlanText(_ value: String?) -> String {
    guard let value else { return "" }
    return value
        .lowercased()
        .split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
        .joined(separator: " ")
}

/// Codex subscription "API-equivalent value" estimation, inspired by sub2api (s2a):
/// price the exact token usage from local rollout logs at official API rates.
/// Prices are per-token USD, checked against the official OpenAI API price list.
enum CodexValue {

    /// Normalize the plan returned by the Codex usage API for display.
    /// Only explicit tier markers have a price. A plain "pro" does not say
    /// whether the subscription is 5x or 20x.
    static func planName(for rawPlan: String?) -> String? {
        planDescriptor(for: rawPlan)?.name
    }

    /// Keep the full plan name for pricing while shortening the visible tier label.
    static func displayPlanName(for plan: String?) -> String? {
        switch normalizedPlanText(plan) {
        case "prolite", "pro 5x": return "5x"
        case "pro 20x": return "20x"
        default: return plan
        }
    }

    /// Monthly subscription price (USD), or nil when the API reports a plan
    /// whose price cannot be inferred safely (for example, enterprise).
    static func planPriceMonthly(for plan: String?) -> Double? {
        planDescriptor(for: plan)?.monthlyPriceUSD
    }

    private static func planDescriptor(for rawPlan: String?) -> PlanDescriptor? {
        let plan = normalizedPlanText(rawPlan)
        guard !plan.isEmpty else { return nil }

        switch plan {
        case "prolite", "pro 5x": return PlanDescriptor(name: "pro 5x", monthlyPriceUSD: 100)
        case "pro 20x": return PlanDescriptor(name: "pro 20x", monthlyPriceUSD: 200)
        case "pro": return PlanDescriptor(name: "pro", monthlyPriceUSD: nil)
        case "plus": return PlanDescriptor(name: "plus", monthlyPriceUSD: 20)
        case "free": return PlanDescriptor(name: "free", monthlyPriceUSD: 0)
        default: break
        }

        return PlanDescriptor(name: plan, monthlyPriceUSD: nil)
    }

    struct Pricing: Sendable {
        let input: Double      // $ per token, uncached input
        let cached: Double     // $ per token, cached input (cache read)
        let output: Double     // $ per token, output (incl. reasoning)
    }

    /// Standard API short-context $/MTok → per-token. Table keyed by model id.
    private static let table: [String: Pricing] = [
        // https://developers.openai.com/api/docs/models/gpt-6.1-sol (2026-10-08)
        "gpt-6.1-sol":       Pricing(input: 2.0e-6,  cached: 0.1e-6,   output: 10.0e-6),
        "gpt-6-astra":       Pricing(input: 10.0e-6, cached: 1.0e-6,   output: 50.0e-6),
        "gpt-6-sol":         Pricing(input: 2.0e-6,  cached: 0.2e-6,   output: 10.0e-6),
        "gpt-6-luna":        Pricing(input: 0.1e-6,  cached: 0.01e-6,  output: 0.5e-6),
        "gpt-5.6-sol":       Pricing(input: 4.0e-6,  cached: 0.4e-6,   output: 20.0e-6),
        "gpt-5.6-terra":     Pricing(input: 2.0e-6,  cached: 0.2e-6,   output: 12.0e-6),
        "gpt-5.6-luna":      Pricing(input: 0.2e-6,  cached: 0.02e-6,  output: 1.2e-6),
        "gpt-5.5":           Pricing(input: 5.0e-6,  cached: 0.5e-6,   output: 30.0e-6),
        "gpt-5.4":           Pricing(input: 2.5e-6,  cached: 0.25e-6,  output: 15.0e-6),
        "gpt-5.3-codex":     Pricing(input: 1.75e-6, cached: 0.175e-6, output: 14.0e-6),
        "gpt-5.2-codex":     Pricing(input: 1.75e-6, cached: 0.175e-6, output: 14.0e-6),
        "gpt-5.1-codex":     Pricing(input: 1.25e-6, cached: 0.125e-6, output: 10.0e-6),
        "gpt-5-codex":       Pricing(input: 1.25e-6, cached: 0.125e-6, output: 10.0e-6),
    ]

    /// Basis for pricing cloud agent (Dots / Work) tokens: their real model mix is not
    /// observable from this machine, so they are priced at GPT-6.1 Sol standard rates —
    /// the basis chosen by the account owner. Documented in README and the UI row.
    static let cloudPricing: Pricing = table["gpt-6.1-sol"]!

    /// Exact match → date-suffix match → GPT-6.1 Sol standard estimate.
    /// The account owner requests this fallback for all unknown/missing model ids.
    static func pricing(for model: String?) -> Pricing? {
        guard let model, !model.isEmpty else { return cloudPricing }
        if let p = table[model] { return p }
        // Strip a trailing date like "-2026-04-23" and retry.
        if let range = model.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression),
           let p = table[String(model[..<range.lowerBound])] {
            return p
        }
        return cloudPricing
    }

    /// One turn's cost from a rollout `last_token_usage` record.
    /// `reasoning_output_tokens` is a subset of output — never added separately.
    static func cost(model: String?, input: Int, cachedInput: Int, output: Int) -> Double? {
        guard input >= 0, cachedInput >= 0, output >= 0,
              let p = pricing(for: model) else { return nil }
        let uncached = max(0, input - cachedInput)
        return Double(uncached) * p.input + Double(cachedInput) * p.cached + Double(output) * p.output
    }

    /// Extrapolate the full weekly quota value from in-window totals.
    /// The used_percent from OpenAI is an internally weighted unit, so we extrapolate
    /// dollars (Σcost / ΣΔpct) rather than raw tokens — cache discounts and model mix
    /// are already baked into Σcost. A reset-aware anchor smooths the noisy
    /// first few percent points; the raw estimate is available above 0%.
    static func extrapolate(costSoFar: Double, pctSoFar: Double) -> (weekly: Double, monthly: Double)? {
        guard pctSoFar.isFinite, pctSoFar > 0, pctSoFar <= 100,
              costSoFar.isFinite, costSoFar > 0 else { return nil }
        let weekly = costSoFar / pctSoFar * 100
        let monthly = weekly * 30.44 / 7
        guard weekly.isFinite, monthly.isFinite else { return nil }
        return (weekly, monthly)
    }

    /// Extrapolate the 100% weekly token limit from observed in-window total tokens
    /// (including cached context reads, matching the Summary Tokens chart & ccusage)
    /// and the current weekly quota percentage.
    static func weeklyLimitText(tokensSoFar: Double, pctSoFar: Double) -> String? {
        guard pctSoFar.isFinite, pctSoFar > 0, pctSoFar <= 100,
              tokensSoFar.isFinite, tokensSoFar > 0 else { return nil }
        let weekly = tokensSoFar / pctSoFar * 100
        guard weekly.isFinite, weekly > 0 else { return nil }
        if weekly >= 1_000_000_000 {
            return String(format: "%.1fB/wk", weekly / 1_000_000_000)
        } else if weekly >= 1_000_000 {
            return String(format: "%.0fM/wk", weekly / 1_000_000)
        } else if weekly >= 1_000 {
            return String(format: "%.0fK/wk", weekly / 1_000)
        }
        return String(format: "%.0f/wk", weekly)
    }
}

/// Same estimation for Claude: local session logs carry exact per-message usage
/// (input / cache_creation / cache_read / output) and the model id. Prices per-token
/// USD from the same LiteLLM mirror; cache creation is split into 5m/1h tiers when
/// the log carries the breakdown (the user runs on the 1h tier).
enum ClaudeValue {

    /// Claude's usage endpoint omits the plan. Claude Code keeps the current
    /// subscription metadata in Keychain, so use both fields when available.
    static func planName(subscriptionType: String?, rateLimitTier: String?) -> String? {
        planDescriptor(subscriptionType: subscriptionType, rateLimitTier: rateLimitTier)?.name
    }

    /// Monthly subscription price (USD), or nil when the reported tier is not
    /// one of the known consumer plans.
    static func planPriceMonthly(for plan: String?) -> Double? {
        let normalized = normalizedPlanText(plan)
        guard !normalized.isEmpty else { return nil }
        if normalized.contains("max") {
            if normalized.contains("20") { return 200 }
            if normalized.contains("5") { return 100 }
            return nil
        }
        if normalized.contains("pro") { return 20 }
        if normalized.contains("free") { return 0 }
        return nil
    }

    private static func planDescriptor(subscriptionType: String?, rateLimitTier: String?) -> PlanDescriptor? {
        let subscription = normalizedPlanText(subscriptionType)
        let tier = normalizedPlanText(rateLimitTier)
        let combined = [subscription, tier].filter { !$0.isEmpty }.joined(separator: " ")
        guard !combined.isEmpty else { return nil }

        if combined.contains("max") {
            if combined.contains("20") { return PlanDescriptor(name: "max 20x", monthlyPriceUSD: 200) }
            if combined.contains("5") { return PlanDescriptor(name: "max 5x", monthlyPriceUSD: 100) }
            return PlanDescriptor(name: "max", monthlyPriceUSD: nil)
        }
        if subscription.contains("pro") || tier.contains("default claude ai") {
            return PlanDescriptor(name: "pro", monthlyPriceUSD: 20)
        }
        if combined.contains("free") {
            return PlanDescriptor(name: "free", monthlyPriceUSD: 0)
        }

        // Keep an unfamiliar provider value visible, but do not invent its price.
        return PlanDescriptor(name: subscription.isEmpty ? tier : subscription, monthlyPriceUSD: nil)
    }

    struct Pricing: Sendable {
        let input: Double
        let cacheRead: Double
        let cacheCreate: Double    // 5-minute ephemeral tier
        let cacheCreate1h: Double  // 1-hour ephemeral tier
        let output: Double
    }

    private static let table: [String: Pricing] = [
        "claude-opus-5-5":   Pricing(input: 4.0e-6,  cacheRead: 0.2e-6,  cacheCreate: 5.0e-6,   cacheCreate1h: 8.0e-6,  output: 20.0e-6),
        "claude-opus-5":     Pricing(input: 5.0e-6,  cacheRead: 0.5e-6,  cacheCreate: 6.25e-6,  cacheCreate1h: 10.0e-6, output: 25.0e-6),
        "claude-opus-4-8":   Pricing(input: 5.0e-6,  cacheRead: 0.5e-6,  cacheCreate: 6.25e-6,  cacheCreate1h: 10.0e-6, output: 25.0e-6),
        "claude-opus-4-5":   Pricing(input: 5.0e-6,  cacheRead: 0.5e-6,  cacheCreate: 6.25e-6,  cacheCreate1h: 10.0e-6, output: 25.0e-6),
        "claude-opus-4-1":   Pricing(input: 15.0e-6, cacheRead: 1.5e-6,  cacheCreate: 18.75e-6, cacheCreate1h: 30.0e-6, output: 75.0e-6),
        "claude-opus-4":     Pricing(input: 15.0e-6, cacheRead: 1.5e-6,  cacheCreate: 18.75e-6, cacheCreate1h: 30.0e-6, output: 75.0e-6),
        // Standard global USD/token, verified against Anthropic on 2026-10-22.
        "claude-sonnet-5-5": Pricing(input: 2.0e-6, cacheRead: 0.1e-6, cacheCreate: 2.5e-6, cacheCreate1h: 4.0e-6, output: 10.0e-6),
        "claude-sonnet-4-6": Pricing(input: 3.0e-6,  cacheRead: 0.3e-6,  cacheCreate: 3.75e-6,  cacheCreate1h: 6.0e-6,  output: 15.0e-6),
        "claude-sonnet-4-5": Pricing(input: 3.0e-6,  cacheRead: 0.3e-6,  cacheCreate: 3.75e-6,  cacheCreate1h: 6.0e-6,  output: 15.0e-6),
        "claude-sonnet-4":   Pricing(input: 3.0e-6,  cacheRead: 0.3e-6,  cacheCreate: 3.75e-6,  cacheCreate1h: 6.0e-6,  output: 15.0e-6),
        "claude-haiku-5-5":  Pricing(input: 0.1e-6, cacheRead: 0.01e-6, cacheCreate: 0.125e-6, cacheCreate1h: 0.2e-6, output: 0.5e-6),
        "claude-haiku-4-5":  Pricing(input: 1.0e-6,  cacheRead: 0.1e-6,  cacheCreate: 1.25e-6,  cacheCreate1h: 2.0e-6,  output: 5.0e-6),
    ]

    /// Price only exact verified IDs and known IDs with a YYYYMMDD suffix.
    static func pricing(for model: String?, inputTokens: Int = 0) -> Pricing? {
        guard let model, !model.isEmpty else { return nil }
        let key: String
        if let range = model.range(of: #"-\d{8}$"#, options: .regularExpression) {
            key = String(model[..<range.lowerBound])
        } else { key = model }
        if key == "claude-haiku-5-5", inputTokens > 100_000 {
            return Pricing(input: 0.5e-6, cacheRead: 0.05e-6, cacheCreate: 0.625e-6,
                cacheCreate1h: 1.0e-6, output: 2.5e-6)
        }
        return table[key]
    }

    static func monthlyValue(stats: TodayStats?, boundary: Date?, usedPercent: Double?) -> Double? {
        guard let stats, let boundary, let statsBoundary = stats.claudeWindowStart,
              abs(statsBoundary.timeIntervalSince(boundary)) < 1,
              stats.claudeWindowUnpriced != true, let cost = stats.claudeWindowCostUSD else { return nil }
        return extrapolate(costSoFar: cost, pctSoFar: usedPercent ?? 0)?.monthly
    }

    static func weeklyLimitText(stats: TodayStats?, boundary: Date?, usedPercent: Double?) -> String? {
        guard let stats, let boundary, let statsBoundary = stats.claudeWindowStart,
              abs(statsBoundary.timeIntervalSince(boundary)) < 1,
              let tokens = stats.claudeWindowTokens, tokens > 0 else { return nil }
        return CodexValue.weeklyLimitText(tokensSoFar: Double(tokens), pctSoFar: usedPercent ?? 0)
    }

    /// One message's cost from a Claude session-log usage record.
    /// Cache creation is split by tier when the log carries the
    /// `cache_creation.ephemeral_5m/1h` breakdown; otherwise all at the 5m rate.
    static func cost(model: String?, input: Int, cacheCreate5m: Int, cacheCreate1h: Int, cacheRead: Int, output: Int) -> Double? {
        guard [input, cacheCreate5m, cacheCreate1h, cacheRead, output].allSatisfy({ $0 >= 0 }),
              let p = pricing(for: model, inputTokens: UsageNumbers.sum(input, cacheCreate5m, cacheCreate1h, cacheRead)) else { return nil }
        return Double(input) * p.input + Double(cacheRead) * p.cacheRead
            + Double(cacheCreate5m) * p.cacheCreate + Double(cacheCreate1h) * p.cacheCreate1h
            + Double(output) * p.output
    }

    /// Same percent-paired extrapolation as Codex (shared math).
    static func extrapolate(costSoFar: Double, pctSoFar: Double) -> (weekly: Double, monthly: Double)? {
        CodexValue.extrapolate(costSoFar: costSoFar, pctSoFar: pctSoFar)
    }
}

/// Antigravity (CLI `agy` + Desktop clients) plan detection and API-equivalent valuation
/// from local transcripts paired with the Gemini group's weekly quota utilization.
enum AntigravityValue {
    /// Strict check for Antigravity server quota group names (e.g. "Gemini" vs "Claude").
    static func isGeminiModel(_ model: String?) -> Bool {
        model?.lowercased().hasPrefix("gemini") == true
    }

    /// Whether a local Antigravity transcript step draws from the Gemini weekly quota pool.
    /// Includes Gemini models, Orchestrator modes (e.g. "Orchestrator (Carbon)"), and legacy/subagent
    /// transcripts that omit the model field; excludes explicitly non-Gemini third-party models.
    static func usesGeminiQuota(_ model: String?) -> Bool {
        guard let raw = model?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return true
        }
        let m = raw.lowercased()
        if m.hasPrefix("claude") || m.hasPrefix("gpt") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") || m.contains("deepseek") {
            return false
        }
        return true
    }

    /// Normalize the `userTier` returned by Antigravity (`GetUserStatus` / `GetLoadCodeAssist`).
    static func planName(tierId: String?, tierName: String? = nil) -> String? {
        planDescriptor(tierId: tierId, tierName: tierName)?.name
    }

    /// Monthly subscription price (USD) for known Google One AI consumer tiers.
    static func planPriceMonthly(for plan: String?) -> Double? {
        planDescriptor(tierId: plan, tierName: nil)?.monthlyPriceUSD
    }

    private static func planDescriptor(tierId: String?, tierName: String?) -> PlanDescriptor? {
        let idText = normalizedPlanText(tierId)
        let nameText = normalizedPlanText(tierName)
        let combined = [idText, nameText].filter { !$0.isEmpty }.joined(separator: " ")
        guard !combined.isEmpty else { return nil }

        if combined.contains("ultra") {
            return PlanDescriptor(name: "ultra", monthlyPriceUSD: 200)
        }
        if combined.contains("pro") {
            return PlanDescriptor(name: "pro", monthlyPriceUSD: 20)
        }
        if combined.contains("free") {
            return PlanDescriptor(name: "free", monthlyPriceUSD: 0)
        }
        if combined.contains("standard") {
            return PlanDescriptor(name: "standard", monthlyPriceUSD: nil)
        }
        let base = (idText.isEmpty ? nameText : idText)
            .replacingOccurrences(of: #"\s*tier$"#, with: "", options: .regularExpression)
        return PlanDescriptor(name: base.isEmpty ? combined : base, monthlyPriceUSD: nil)
    }

    struct Pricing: Sendable {
        let input: Double
        let cacheRead: Double
        let cacheWrite: Double
        let output: Double
    }

    // Standard global USD/token for Gemini 4 Argon ($4 / $0.20 cached / $20 per MTok)
    // and Gemini 3.7 Flash ($1.50 / $0.15 cached / $7.50 per MTok).
    private static let argonPricing = Pricing(
        input: 4.0e-6, cacheRead: 0.20e-6, cacheWrite: 4.0e-6, output: 20.0e-6
    )
    private static let flashPricing = Pricing(
        input: 1.50e-6, cacheRead: 0.15e-6, cacheWrite: 1.50e-6, output: 7.50e-6
    )

    static func cost(model: String?, input: Int, cacheRead: Int, cacheWrite: Int, output: Int) -> Double {
        let m = (model ?? "").lowercased()
        if m.hasPrefix("claude-") {
            let stripped = m.replacingOccurrences(
                of: #"-(low|medium|high|max|xhigh)$"#, with: "", options: .regularExpression
            )
            if let claudeCost = ClaudeValue.cost(
                model: stripped, input: max(0, input), cacheCreate5m: max(0, cacheWrite),
                cacheCreate1h: 0, cacheRead: max(0, cacheRead), output: max(0, output)
            ) {
                return claudeCost
            }
        }
        let p = (m.isEmpty || m.contains("flash")) ? flashPricing : argonPricing
        return Double(max(0, input)) * p.input
            + Double(max(0, cacheRead)) * p.cacheRead
            + Double(max(0, cacheWrite)) * p.cacheWrite
            + Double(max(0, output)) * p.output
    }

    static func monthlyValue(
        stats: TodayStats?, boundary: Date?, usedPercent: Double?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        allowFallbackScan: Bool = true
    ) -> Double? {
        guard let boundary, let usedPercent, usedPercent > 0 else { return nil }
        let cost: Double
        if let stats, let statsBoundary = stats.antigravityWindowStart,
           abs(statsBoundary.timeIntervalSince(boundary)) < 1,
           let cachedCost = stats.antigravityWindowCostUSD {
            cost = cachedCost
        } else if allowFallbackScan {
            cost = AntigravityUsage.windowCostUSD(since: boundary, home: home)
        } else {
            return nil
        }
        return CodexValue.extrapolate(costSoFar: cost, pctSoFar: usedPercent)?.monthly
    }

    static func weeklyLimitText(
        stats: TodayStats?, boundary: Date?, usedPercent: Double?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        allowFallbackScan: Bool = true
    ) -> String? {
        guard let boundary, let usedPercent, usedPercent > 0 else { return nil }
        let tokens: Int
        if let stats, let statsBoundary = stats.antigravityWindowStart,
           abs(statsBoundary.timeIntervalSince(boundary)) < 1,
           let cachedTokens = stats.antigravityWindowTokens {
            tokens = cachedTokens
        } else if allowFallbackScan {
            tokens = AntigravityUsage.windowTokens(since: boundary, home: home)
        } else {
            return nil
        }
        return CodexValue.weeklyLimitText(tokensSoFar: Double(tokens), pctSoFar: usedPercent)
    }
}
