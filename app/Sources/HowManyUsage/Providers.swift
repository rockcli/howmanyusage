import Foundation

/// Official API clients for Codex, Claude, and DeepSeek.
enum Providers {
    private static let apiSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        if let proxy = envProxy() {
            config.connectionProxyDictionary = proxy
        }
        return URLSession(configuration: config)
    }()

    private static let localRPCSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0]
        return URLSession(configuration: config)
    }()

    static func fetchAll(
        only: Set<String>? = nil,
        skip: Set<String> = [],
        includeLocalUsage: Bool = true
    ) async -> [ProviderResult] {
        let enabled = only ?? ProviderDetection.installedProviders()
        async let codex: ProviderResult? = enabled.contains("codex")
            ? (skip.contains("codex") ? skipResult("codex", "Codex") : await fetchCodex())
            : nil
        async let claude: ProviderResult? = enabled.contains("claude")
            ? (skip.contains("claude") ? skipResult("claude", "Claude") : await fetchClaude())
            : nil
        async let antigravity: ProviderResult? = enabled.contains("antigravity")
            ? (skip.contains("antigravity") ? skipResult("antigravity", "Google") : await fetchAntigravity())
            : nil
        async let deepseek: ProviderResult? = enabled.contains("deepseek")
            ? (skip.contains("deepseek") ? skipResult("deepseek", "DeepSeek") : await fetchDeepSeek(includeLocalUsage: includeLocalUsage))
            : nil
        async let colab: ProviderResult? = enabled.contains("colab")
            ? (skip.contains("colab") ? skipResult("colab", "Colab") : await fetchColab())
            : nil
        return await [codex, claude, antigravity, deepseek, colab].compactMap { $0 }
    }

    /// Placeholder for a throttled fetch: ok but no data, so the caller reuses its cache.
    private static func skipResult(_ id: String, _ name: String) -> ProviderResult {
        ProviderResult(id: id, name: name, plan: nil, weekly: nil, fiveHour: nil, balance: nil, todayUsage: nil, error: nil)
    }

    // MARK: - HTTP

    private static func fetchJSON(
        _ urlString: String, method: String = "GET",
        headers: [String: String] = [:], body: [String: Any]? = nil,
        timeoutMs: Double = 15
    ) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else {
            throw ProvidersError("Invalid URL: \(urlString)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeoutMs
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        // Reuse a single ephemeral session (with env-var or system proxy settings)
        let (data, response) = try await apiSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if url.host == "api.anthropic.com", url.path == "/api/oauth/usage" {
                throw ClaudeQuota.HTTPError(status: code)
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProvidersError("HTTP \(code): \(body.prefix(200))")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProvidersError("Response is not JSON")
        }
        return obj
    }

    private static func getJSON(_ urlString: String, headers: [String: String]) async throws -> [String: Any] {
        try await fetchJSON(urlString, headers: headers)
    }

    /// Claude OAuth refresh (unused now — read-only mode; kept as documentation)
    /// Note: refresh tokens rotate, so any refresh invalidates the other party's old token.
    /// To avoid disturbing Claude Code, the app only reads the keychain and never refreshes.
    // private static func refreshClaudeTokens(_ old: ClaudeOAuthTokens) async throws -> ClaudeOAuthTokens { ... }

    /// Parse http_proxy / https_proxy environment variables
    private static func envProxy() -> [String: Any]? {
        let env = ProcessInfo.processInfo.environment
        let raw = env["https_proxy"] ?? env["HTTPS_PROXY"] ?? env["http_proxy"] ?? env["HTTP_PROXY"]
        guard let raw, !raw.isEmpty, let url = URL(string: raw), let host = url.host else { return nil }
        let port = url.port ?? 80
        return [
            "HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
            "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port,
        ]
    }

    // MARK: - Codex（chatgpt.com/backend-api/wham/usage）

    private static func fetchCodex() async -> ProviderResult {
        do {
            let auth = try Auth.codex()
            var headers = [
                "Authorization": "Bearer \(auth.accessToken)",
                "User-Agent": "codex-cli",
                "Accept": "application/json",
            ]
            if let accountId = auth.accountId {
                headers["ChatGPT-Account-Id"] = accountId
            }
            let data = try await getJSON("https://chatgpt.com/backend-api/wham/usage", headers: headers)
            let rateLimit = data["rate_limit"] as? [String: Any]
            let primary = rateLimit?["primary_window"] as? [String: Any]
            let secondary = rateLimit?["secondary_window"] as? [String: Any]
            let windows = codexWindows(primary: primary, secondary: secondary)
            return ProviderResult(
                id: "codex",
                name: "Codex",
                plan: CodexValue.planName(for: data["plan_type"] as? String),
                weekly: windows.weekly,
                fiveHour: windows.fiveHour,
                balance: nil,
                todayUsage: nil,
                error: nil
            )
        } catch {
            return ProviderResult(id: "codex", name: "Codex", plan: nil, weekly: nil, fiveHour: nil, balance: nil, todayUsage: nil, error: error.localizedDescription)
        }
    }

    // MARK: - Claude（api.anthropic.com/api/oauth/usage）

    static func requestClaudeQuota(_ credential: ClaudeQuotaCredential) async throws -> [String: Any] {
        try await getJSON("https://api.anthropic.com/api/oauth/usage", headers: [
            "Authorization": "Bearer \(credential.accessToken)",
            "Accept": "application/json",
            "anthropic-beta": Auth.claudeOAuthBeta,
        ])
    }

    private static func fetchClaude() async -> ProviderResult {
        do {
            let (data, credential) = try await ClaudeQuota.fetch()
            let fiveHour = data["five_hour"] as? [String: Any]
            let sevenDay = data["seven_day"] as? [String: Any]
            return ProviderResult(
                id: "claude",
                name: "Claude",
                // The usage API omits the plan; use metadata from the credential that succeeded.
                plan: ClaudeValue.planName(
                    subscriptionType: credential.subscriptionType,
                    rateLimitTier: credential.rateLimitTier
                ),
                weekly: window(kind: "weekly", dict: sevenDay),
                fiveHour: window(kind: "fiveHour", dict: fiveHour),
                balance: nil,
                todayUsage: nil,
                error: nil
            )
        } catch {
            return ProviderResult(id: "claude", name: "Claude", plan: nil, weekly: nil, fiveHour: nil, balance: nil, todayUsage: nil, error: error.localizedDescription)
        }
    }

    // MARK: - DeepSeek (api.deepseek.com/user/balance + today usage)

    private static func fetchDeepSeek(includeLocalUsage: Bool = true) async -> ProviderResult {
        do {
            let key = try Auth.deepSeek()
            let balanceData = try await getJSON("https://api.deepseek.com/user/balance", headers: [
                "Authorization": "Bearer \(key)",
                "Accept": "application/json",
            ])
            var balance: Balance?
            if let infos = balanceData["balance_infos"] as? [[String: Any]], let first = infos.first {
                balance = Balance(
                    currency: first["currency"] as? String ?? "CNY",
                    total: number(first["total_balance"]) ?? 0,
                    granted: number(first["granted_balance"]) ?? 0,
                    toppedUp: number(first["topped_up_balance"]) ?? 0
                )
            }
            let base = ProviderResult(
                id: "deepseek",
                name: "DeepSeek",
                plan: nil,
                weekly: nil,
                fiveHour: nil,
                balance: balance,
                todayUsage: nil,
                error: nil
            )
            return enrichDeepSeekUsage(base, includeLocalLogs: includeLocalUsage)
        } catch {
            return ProviderResult(id: "deepseek", name: "DeepSeek", plan: nil, weekly: nil, fiveHour: nil, balance: nil, todayUsage: nil, error: error.localizedDescription)
        }
    }

    /// Merge DeepSeek today's usage from local pi/dsh logs (when requested) and observed wallet balance drops.
    static func enrichDeepSeekUsage(_ result: ProviderResult, includeLocalLogs: Bool) -> ProviderResult {
        guard result.id == "deepseek", result.ok else { return result }
        var today = includeLocalLogs ? PiUsage.todayDeepSeek() : (result.todayUsage ?? DailyUsage(
            inputTokens: 0, outputTokens: 0, totalTokens: 0, cost: 0, currency: "CNY"
        ))
        if let balance = result.balance, balance.currency.uppercased() == "CNY",
           let observed = PiUsage.todayCostFromBalance(current: balance.total) {
            today = DailyUsage(
                inputTokens: today.inputTokens,
                outputTokens: today.outputTokens,
                totalTokens: today.totalTokens,
                cost: observed.cost,
                currency: "CNY",
                costIsEstimated: true,
                costIsLowerBound: true,
                costNote: observed.rechargeObserved ? "observed; recharge may hide spend"
                    : (observed.incomplete ? "observed; partial day or sampling gaps" : "observed balance drops")
            )
        }
        return ProviderResult(
            id: result.id,
            name: result.name,
            plan: result.plan,
            weekly: result.weekly,
            fiveHour: result.fiveHour,
            balance: result.balance,
            todayUsage: (includeLocalLogs || today.cost > 0 || today.totalTokens > 0) ? today : nil,
            error: result.error,
            stale: result.stale
        )
    }

    // MARK: - Antigravity (local daemon RetrieveUserQuotaSummary + GetUserStatus)

    private struct AntigravityHubEndpoint {
        let httpPort: Int
        let csrfToken: String
        let mtime: Date
    }

    private static func discoverAntigravityEndpoints(home: URL) -> [AntigravityHubEndpoint] {
        let fm = FileManager.default
        var endpoints: [AntigravityHubEndpoint] = []
        for dir in [".gemini/antigravity/daemon", ".gemini/antigravity-ide/daemon", ".gemini/antigravity-cli/daemon"] {
            let folder = home.appendingPathComponent(dir)
            guard let files = try? fm.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.lastPathComponent.hasPrefix("hub_") && file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let port = integer(obj["httpPort"]), (1...65535).contains(port),
                      let csrf = obj["csrfToken"] as? String, !csrf.isEmpty else { continue }
                if let rawPID = integer(obj["pid"]), let pid = pid_t(exactly: rawPID),
                   pid > 0, kill(pid, 0) != 0, errno == ESRCH {
                    continue
                }
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                endpoints.append(AntigravityHubEndpoint(httpPort: port, csrfToken: csrf, mtime: mtime))
            }
        }
        return endpoints.sorted { $0.mtime > $1.mtime }
    }

    private static func callAntigravityRPC(port: Int, csrfToken: String, method: String) async throws -> [String: Any] {
        guard let url = URL(string: "http://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/\(method)") else {
            throw ProvidersError("Invalid Antigravity RPC URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await localRPCSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ProvidersError("Antigravity RPC \(method) HTTP \(code)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProvidersError("Antigravity RPC \(method) invalid JSON")
        }
        return obj
    }

    static func parseAntigravityUserTier(userStatus: [String: Any]?, loadCodeAssist: [String: Any]?) -> String? {
        if let status = userStatus?["userStatus"] as? [String: Any],
           let tier = status["userTier"] as? [String: Any],
           let plan = AntigravityValue.planName(tierId: tier["id"] as? String, tierName: tier["name"] as? String) {
            return plan
        }
        let resp = (loadCodeAssist?["response"] as? [String: Any]) ?? loadCodeAssist
        if let paid = resp?["paidTier"] as? [String: Any],
           let plan = AntigravityValue.planName(tierId: paid["id"] as? String, tierName: paid["name"] as? String) {
            return plan
        }
        if let current = resp?["currentTier"] as? [String: Any],
           let plan = AntigravityValue.planName(tierId: current["id"] as? String, tierName: current["name"] as? String) {
            return plan
        }
        return nil
    }

    static func parseAntigravityQuotaSummary(_ payload: [String: Any]) -> (weekly: RateWindow?, fiveHour: RateWindow?) {
        let resp = (payload["response"] as? [String: Any]) ?? payload
        var geminiBuckets: [[String: Any]] = []
        func appendBuckets(_ buckets: [[String: Any]], geminiGroup: Bool = false) {
            geminiBuckets += buckets.filter {
                geminiGroup || ($0["bucketId"] as? String)?.lowercased().hasPrefix("gemini-") == true
            }
        }
        if let groups = resp["groups"] as? [[String: Any]] {
            for g in groups {
                if let b = g["buckets"] as? [[String: Any]] {
                    // Group metadata identifies opaque bucket IDs too. Never use an
                    // unrelated model group's percentage with Gemini transcript costs.
                    appendBuckets(b, geminiGroup: AntigravityValue.isGeminiModel(g["displayName"] as? String))
                }
            }
        }
        if let top = resp["buckets"] as? [[String: Any]] {
            appendBuckets(top)
        }

        func remainingFraction(_ bucket: [String: Any]) -> Double? {
            if let raw = bucket["remainingFraction"], !(raw is NSNull) {
                return number(raw).flatMap { (0...1).contains($0) ? $0 : nil }
            }
            // Protobuf omits a zero fraction. Only a usable reset makes that
            // omission evidence of exhaustion; null/invalid reset data is unknown.
            return parseReset(bucket["resetTime"]).0 != nil ? 0 : nil
        }

        func pickWindow(kind: String, windowTag: String) -> RateWindow? {
            let matching = geminiBuckets.filter { bucket in
                let id = (bucket["bucketId"] as? String)?.lowercased() ?? ""
                let window = (bucket["window"] as? String)?.lowercased()
                return window.map { $0 == windowTag } ?? id.hasSuffix("-\(windowTag)")
            }
            guard let chosen = matching.min(by: {
                // A complete 0%-used reading must beat an unknown reading even
                // when both would otherwise sort as remainingFraction == 1.
                if (remainingFraction($0) != nil) != (remainingFraction($1) != nil) {
                    return remainingFraction($0) != nil
                }
                return (remainingFraction($0) ?? 1.0) < (remainingFraction($1) ?? 1.0)
            }) else { return nil }
            let rem = remainingFraction(chosen)
            let usedPct = rem.map { max(0, min(100, (1.0 - $0) * 100.0)) }
            let reset = parseReset(chosen["resetTime"])
            return RateWindow(
                kind: kind,
                usedPercent: usedPct,
                used: nil,
                limit: nil,
                remaining: nil,
                resetAt: reset.0,
                resetsInSeconds: reset.1
            )
        }

        return (
            weekly: pickWindow(kind: "weekly", windowTag: "weekly"),
            fiveHour: pickWindow(kind: "fiveHour", windowTag: "5h")
        )
    }

    static func fetchAntigravity(home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> ProviderResult {
        let endpoints = discoverAntigravityEndpoints(home: home)
        guard !endpoints.isEmpty else {
            return ProviderResult(
                id: "antigravity", name: "Google", plan: nil, weekly: nil, fiveHour: nil,
                balance: nil, todayUsage: nil, error: "Antigravity is not running"
            )
        }
        var lastError = "Antigravity quota unavailable"
        for ep in endpoints {
            do {
                async let quotaTask = callAntigravityRPC(port: ep.httpPort, csrfToken: ep.csrfToken, method: "RetrieveUserQuotaSummary")
                async let statusTask = try? callAntigravityRPC(port: ep.httpPort, csrfToken: ep.csrfToken, method: "GetUserStatus")
                let quotaData = try await quotaTask
                let statusData = await statusTask
                var loadData: [String: Any]?
                if parseAntigravityUserTier(userStatus: statusData, loadCodeAssist: nil) == nil {
                    loadData = try? await callAntigravityRPC(port: ep.httpPort, csrfToken: ep.csrfToken, method: "GetLoadCodeAssist")
                }
                let plan = parseAntigravityUserTier(userStatus: statusData, loadCodeAssist: loadData)
                let windows = parseAntigravityQuotaSummary(quotaData)
                return ProviderResult(
                    id: "antigravity",
                    name: "Google",
                    plan: plan,
                    weekly: windows.weekly,
                    fiveHour: windows.fiveHour,
                    balance: nil,
                    todayUsage: nil,
                    error: nil
                )
            } catch {
                lastError = error.localizedDescription
            }
        }
        return ProviderResult(
            id: "antigravity", name: "Google", plan: nil, weekly: nil, fiveHour: nil,
            balance: nil, todayUsage: nil, error: lastError
        )
    }

    // MARK: - Google Colab (colab.research.google.com/tun/m/ccu-info)

    private static let colabTokenLock = NSLock()
    private static var cachedColabToken: (token: String, expiresAt: Date)?

    private static func getCachedColabToken() -> (token: String, expiresAt: Date)? {
        colabTokenLock.lock()
        defer { colabTokenLock.unlock() }
        return cachedColabToken
    }

    private static func setCachedColabToken(_ token: String, expiresAt: Date) {
        colabTokenLock.lock()
        defer { colabTokenLock.unlock() }
        cachedColabToken = (token, expiresAt)
    }

    private static func validColabAccessToken(_ auth: Auth.ColabAuth, forceRefresh: Bool = false) async throws -> String {
        let now = Date()
        if !forceRefresh {
            let memToken = getCachedColabToken()
            if let memToken, memToken.expiresAt > now.addingTimeInterval(60) {
                return memToken.token
            }
            if let diskToken = auth.accessToken,
               let expiresAt = auth.expiresAt,
               expiresAt > now.addingTimeInterval(60) {
                return diskToken
            }
        }
        guard let refreshToken = auth.refreshToken,
              let clientID = auth.clientID,
              let clientSecret = auth.clientSecret,
              let url = URL(string: auth.tokenURI) else {
            if let diskToken = auth.accessToken, !forceRefresh {
                return diskToken
            }
            throw ProvidersError("Colab OAuth token expired and cannot be refreshed; run `colab usage`")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)

        let (data, response) = try await apiSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newToken = obj["access_token"] as? String, !newToken.isEmpty else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ProvidersError("Colab OAuth refresh HTTP \(code)")
        }
        let expiresIn = number(obj["expires_in"]) ?? 3600
        let expiresAt = Date().addingTimeInterval(expiresIn)
        setCachedColabToken(newToken, expiresAt: expiresAt)
        return newToken
    }

    static func parseColabCCUInfo(_ data: Data) throws -> (balance: Double, hourlyRate: Double, activeCount: Int, expiresAt: Date?) {
        guard var text = String(data: data, encoding: .utf8) else {
            throw ProvidersError("Colab ccu-info invalid UTF-8")
        }
        if text.hasPrefix(")]}'\n") {
            text.removeFirst(5)
        } else if text.hasPrefix(")]}'") {
            text.removeFirst(4)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let balance = number(obj["currentBalance"]) ?? number(obj["paidComputeUnitsBalance"]) else {
            throw ProvidersError("Colab ccu-info missing currentBalance")
        }
        let hourlyRate = number(obj["consumptionRateHourly"]) ?? 0
        let activeCount = integer(obj["assignmentsCount"]) ?? 0
        let rawExpiry = obj["expirationTime"] ?? obj["expiresAt"] ?? obj["expiry"]
            ?? obj["nextExpirationTime"] ?? obj["paidComputeUnitsExpirationTime"]
        let expiresAt = parseReset(rawExpiry).0
        return (balance, hourlyRate, activeCount, expiresAt)
    }

    private static let colabExpiryFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()

    private static func requestColabCCUInfo(accessToken: String) async throws -> (Data, Int) {
        guard let url = URL(string: "https://colab.research.google.com/tun/m/ccu-info?authuser=0") else {
            throw ProvidersError("Invalid Colab ccu-info URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("colab-cli", forHTTPHeaderField: "X-Colab-Client-Agent")

        let (data, response) = try await apiSession.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (data, code)
    }

    static func fetchColab(home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> ProviderResult {
        do {
            let auth = try Auth.colab(home: home)
            var token = try await validColabAccessToken(auth)
            var (data, status) = try await requestColabCCUInfo(accessToken: token)
            if (status == 401 || status == 403), auth.refreshToken != nil {
                token = try await validColabAccessToken(auth, forceRefresh: true)
                (data, status) = try await requestColabCCUInfo(accessToken: token)
            }
            guard (200..<300).contains(status) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw ProvidersError("HTTP \(status): \(body.prefix(160))")
            }
            let info = try parseColabCCUInfo(data)
            let balance = Balance(
                currency: "CU",
                total: info.balance,
                granted: 0,
                toppedUp: info.balance
            )
            let observed = PiUsage.todayColabFromBalance(current: info.balance, home: home)
            var noteParts: [String] = []
            if let exp = info.expiresAt {
                noteParts.append("exp \(colabExpiryFormatter.string(from: exp))")
            }
            if info.hourlyRate > 0 || info.activeCount > 0 {
                noteParts.append(String(format: "%.2f CU/h · %d active", info.hourlyRate, info.activeCount))
            }
            let rateNote: String? = noteParts.isEmpty ? nil : noteParts.joined(separator: " · ")
            let today = DailyUsage(
                inputTokens: 0,
                outputTokens: 0,
                totalTokens: 0,
                cost: observed?.cost ?? 0,
                currency: "CU",
                costIsEstimated: true,
                costIsLowerBound: true,
                costNote: rateNote
            )
            return ProviderResult(
                id: "colab",
                name: "Colab",
                plan: nil,
                weekly: nil,
                fiveHour: nil,
                balance: balance,
                todayUsage: today,
                error: nil
            )
        } catch {
            return ProviderResult(
                id: "colab", name: "Colab", plan: nil, weekly: nil, fiveHour: nil,
                balance: nil, todayUsage: nil, error: error.localizedDescription
            )
        }
    }

    /// Snapshot + reset-window inputs for the state store (shared by GUI and --once).
    static func stateInputs(
        _ report: [ProviderResult],
        recordDeepSeekBalance: Bool = true,
        recordColabBalance: Bool = true
    ) -> (windows: [String: String], snapshot: UsageSnapshot) {
        var windows: [String: String] = [:]
        for p in report {
            if let w = p.weekly, let reset = w.resetAt {
                windows["\(p.id).weekly"] = String(reset.timeIntervalSince1970)
            }
            if let f = p.fiveHour, let reset = f.resetAt {
                windows["\(p.id).fiveHour"] = String(reset.timeIntervalSince1970)
            }
        }
        let r = { (id: String) in report.first { $0.id == id } }
        let snap = UsageSnapshot(
            ts: Date(),
            codexWeekly: r("codex")?.weekly?.usedPercent,
            codexWeeklyReset: r("codex")?.weekly?.resetAt.map { String($0.timeIntervalSince1970) },
            codex5h: r("codex")?.fiveHour?.usedPercent,
            codex5hReset: r("codex")?.fiveHour?.resetAt.map { String($0.timeIntervalSince1970) },
            claudeWeekly: r("claude")?.weekly?.usedPercent,
            claudeWeeklyReset: r("claude")?.weekly?.resetAt.map { String($0.timeIntervalSince1970) },
            claude5h: r("claude")?.fiveHour?.usedPercent,
            claude5hReset: r("claude")?.fiveHour?.resetAt.map { String($0.timeIntervalSince1970) },
            antigravityWeekly: r("antigravity")?.weekly?.usedPercent,
            antigravityWeeklyReset: r("antigravity")?.weekly?.resetAt.map { String($0.timeIntervalSince1970) },
            antigravity5h: r("antigravity")?.fiveHour?.usedPercent,
            antigravity5hReset: r("antigravity")?.fiveHour?.resetAt.map { String($0.timeIntervalSince1970) },
            dsBalance: recordDeepSeekBalance && r("deepseek")?.stale != true ? r("deepseek")?.balance?.total : nil,
            dsTodayTokens: r("deepseek")?.todayUsage?.totalTokens,
            colabBalance: recordColabBalance && r("colab")?.stale != true ? r("colab")?.balance?.total : nil
        )
        return (windows, snap)
    }

    // MARK: - Parsing helpers

    /// Split Codex's two quota slots by their actual window duration.
    ///
    /// The rollout log currently reports the 5h slot as `primary` and the 7d
    /// slot as `secondary`; older API responses used the opposite ordering.
    /// `window_minutes` is authoritative when present, with reset distance as
    /// a compatibility fallback for responses that omit the duration.
    static func codexWindows(
        primary: [String: Any]?, secondary: [String: Any]?
    ) -> (weekly: RateWindow?, fiveHour: RateWindow?) {
        let candidates = [primary, secondary].compactMap { $0 }
        var weekly: RateWindow?
        var fiveHour: RateWindow?
        var unknown: [[String: Any]] = []

        for dict in candidates {
            switch codexWindowKind(dict) {
            case "weekly":
                weekly = weekly ?? window(kind: "weekly", dict: dict)
            case "fiveHour":
                fiveHour = fiveHour ?? window(kind: "fiveHour", dict: dict)
            default:
                unknown.append(dict)
            }
        }

        // Legacy fallback: when neither slot carries enough metadata, retain
        // the original primary=weekly, secondary=5h mapping.
        if weekly == nil && fiveHour == nil {
            weekly = window(kind: "weekly", dict: primary)
            fiveHour = window(kind: "fiveHour", dict: secondary)
        } else {
            // If exactly one slot was identifiable, use the remaining slot for
            // the other role instead of silently dropping it.
            if weekly == nil, let dict = unknown.first {
                weekly = window(kind: "weekly", dict: dict)
            }
            if fiveHour == nil, let dict = unknown.first {
                fiveHour = window(kind: "fiveHour", dict: dict)
            }
        }
        return (weekly, fiveHour)
    }

    private static func codexWindowKind(_ dict: [String: Any]) -> String? {
        if let minutes = integer(dict["window_minutes"] ?? dict["window_duration_minutes"]) {
            switch minutes {
            case 300: return "fiveHour"
            case 10_080: return "weekly"
            default: break
            }
        }

        // Some older responses omit window_minutes but include a reset time.
        // A reset within 12h is the short slot; a reset at least a day away is
        // the weekly slot. Ambiguous values fall through to the legacy mapping.
        if let remaining = parseReset(dict["reset_at"] ?? dict["resets_at"]).1 {
            if remaining >= 0, remaining <= 12 * 3600 { return "fiveHour" }
            if remaining >= 24 * 3600 { return "weekly" }
        }
        return nil
    }

    /// Parse a numeric API field that may be encoded as a number or a string.
    private static func number(_ value: Any?) -> Double? {
        UsageNumbers.finite(value)
    }

    private static func integer(_ value: Any?) -> Int? {
        UsageNumbers.integer(value)
    }

    /// Parse reset time: ISO8601 or unix seconds
    private static func parseReset(_ value: Any?) -> (Date?, TimeInterval?) {
        if let iso = value as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            if let d = fractional.date(from: iso) ?? plain.date(from: iso) {
                return (d, d.timeIntervalSinceNow)
            }
            return (nil, nil)
        }
        if let epoch = number(value), let d = UsageNumbers.date(epoch: epoch) {
            return (d, d.timeIntervalSinceNow)
        }
        return (nil, nil)
    }

    /// Percent window (Codex / Claude)
    private static func window(kind: String, dict: [String: Any]?) -> RateWindow? {
        guard let dict else { return nil }
        // Codex uses used_percent, Claude uses utilization
        let pct = UsageNumbers.percent(number(dict["used_percent"]) ?? number(dict["utilization"]))
        let reset = parseReset(dict["reset_at"] ?? dict["resets_at"])
        return RateWindow(
            kind: kind,
            usedPercent: pct,
            used: nil,
            limit: nil,
            remaining: nil,
            resetAt: reset.0,
            resetsInSeconds: reset.1
        )
    }

}

struct ProvidersError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
