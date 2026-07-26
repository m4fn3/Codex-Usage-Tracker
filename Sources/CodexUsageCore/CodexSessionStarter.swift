//
//  CodexSessionStarter.swift
//  Codex Usage Tracker
//
//  Sends the one throwaway request that anchors a fresh rate-limit window (see
//  CodexAutoStart.swift for why that matters). This is the only place the app
//  ever *spends* quota, so it is deliberately as small as a Codex turn can be:
//  one "hi", no tools, nothing stored.
//
//    POST https://chatgpt.com/backend-api/codex/responses
//    Authorization: Bearer <access_token>
//    ChatGPT-Account-Id: <account_id>
//    { "model": …, "input": [ "hi" ], "store": false, "stream": true, … }
//
//  The model has to be one the account may actually use, and those slugs change
//  every few months (gpt-5.1-codex → gpt-5.6-luna → …). Hard-coding one would
//  rot, so we ask the server which models this account has:
//
//    GET https://chatgpt.com/backend-api/codex/models?client_version=<v>
//    → { "models": [ { "slug": "gpt-5.6-sol", "visibility": "list", … } ] }
//
//  and fall back to the model the local CLI is configured with.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CodexSessionStartError: Error, Sendable, Equatable {
    /// Tokens are dead — only a re-login fixes this.
    case unauthorized
    /// Neither the server catalog nor the local config named a usable model.
    case noModelAvailable
    /// The server refused the request (400) — nothing ran, nothing was charged.
    case rejected(String?)
    case http(Int)
    /// 2xx, but the stream never reported a completed response, so we can't claim
    /// the window was anchored. Retried (a bounded number of times) by the policy.
    case incompleteStream
    case transport(String)
}

public struct CodexSessionStartResult: Sendable, Equatable {
    /// The model the accepted request actually used.
    public var model: String
    /// Reasoning effort sent with it, if any.
    public var effort: String?

    public init(model: String, effort: String?) {
        self.model = model
        self.effort = effort
    }
}

public enum CodexSessionStarter {

    static let responsesPath = "/codex/responses"
    static let modelsPath = "/codex/models"

    /// Sent as `client_version` when asking for the model catalog: the endpoint
    /// requires it and uses it to hide models that need a newer CLI. Only affects
    /// which models come back, never how the request is billed.
    static let clientVersion = "0.145.0"

    /// The whole payload: a greeting and an instruction to answer in one word, so
    /// the turn ends after a handful of tokens.
    static let prompt = "hi"
    static let instructions = "Reply with exactly one word: ok"

    /// Models we prefer when several are available — the small ones cost the least
    /// of the window we're about to open.
    static let cheapModelMarkers = ["mini", "nano"]
    /// Cheapest reasoning efforts, in order of preference.
    static let cheapEfforts = ["none", "minimal", "low"]

    // MARK: - Entry point

    /// Sends the anchoring request for `auth`'s account.
    ///
    /// Retries *inside* one call only on a 400 (the request was refused before it
    /// ran, so nothing was charged and a different model/shape is worth a try).
    /// Every other failure propagates so the caller's attempt bookkeeping — not a
    /// loop in here — decides whether to spend another request later.
    public static func start(
        auth: CodexAuth,
        session: URLSession = .shared,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> CodexSessionStartResult {
        let candidates = await modelCandidates(auth: auth, session: session, env: env)
        guard !candidates.isEmpty else { throw CodexSessionStartError.noModelAvailable }

        var lastRejection: CodexSessionStartError = .noModelAvailable
        for choice in candidates {
            // First the full CLI-shaped payload, then a stripped-down one in case a
            // field we send has been retired server-side.
            for minimal in [false, true] {
                do {
                    try await send(auth: auth, choice: choice, minimal: minimal, session: session, env: env)
                    return CodexSessionStartResult(
                        model: choice.slug,
                        effort: minimal ? nil : choice.effort
                    )
                } catch CodexSessionStartError.rejected(let detail) {
                    lastRejection = .rejected(detail)
                    // "…model is not supported when using Codex with a ChatGPT
                    // account" — reshaping the body won't help, try another model.
                    if detail?.localizedCaseInsensitiveContains("model") == true { break }
                }
            }
        }
        throw lastRejection
    }

    // MARK: - Request

    static func responsesURL(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        URL(string: CodexUsageAPI.baseURLString(env: env) + responsesPath)
            ?? URL(string: CodexUsageAPI.defaultBaseURL + responsesPath)!
    }

    private static func send(
        auth: CodexAuth,
        choice: ModelChoice,
        minimal: Bool,
        session: URLSession,
        env: [String: String]
    ) async throws {
        let conversationId = UUID().uuidString
        var request = URLRequest(
            url: responsesURL(env: env),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 120   // reasoning models can take a while even for "hi"
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("CodexUsageTracker", forHTTPHeaderField: "User-Agent")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue(conversationId, forHTTPHeaderField: "session_id")
        request.setValue(conversationId, forHTTPHeaderField: "conversation_id")
        if let accountId = auth.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: body(choice: choice, minimal: minimal, conversationId: conversationId)
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CodexSessionStartError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CodexSessionStartError.transport("invalid response")
        }
        switch http.statusCode {
        case 200...299:
            guard streamCompleted(data) else { throw CodexSessionStartError.incompleteStream }
        case 401, 403:
            throw CodexSessionStartError.unauthorized
        case 400:
            throw CodexSessionStartError.rejected(errorDetail(data))
        default:
            throw CodexSessionStartError.http(http.statusCode)
        }
    }

    static func body(choice: ModelChoice, minimal: Bool, conversationId: String) -> [String: Any] {
        let input: [[String: Any]] = [[
            "type": "message",
            "role": "user",
            "content": [["type": "input_text", "text": prompt]],
        ]]
        if minimal {
            return ["model": choice.slug, "input": input, "store": false, "stream": true]
        }
        var body: [String: Any] = [
            "model": choice.slug,
            "instructions": instructions,
            "input": input,
            "tools": [],
            "tool_choice": "auto",
            "parallel_tool_calls": false,
            "store": false,
            "stream": true,
            "include": ["reasoning.encrypted_content"],
            "prompt_cache_key": conversationId,
        ]
        if let effort = choice.effort {
            body["reasoning"] = ["effort": effort]
        }
        return body
    }

    /// True when the SSE stream carried a finished response. A 2xx alone only means
    /// the stream opened; treating that as success would let a turn that died
    /// mid-stream (and so anchored nothing) be recorded as done.
    static func streamCompleted(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("response.completed") || text.contains("\"status\":\"completed\"")
    }

    /// Pulls the human-readable message out of an error body, which the backend
    /// returns as either `{"detail": …}` or `{"error": {"message": …}}`.
    static func errorDetail(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)?.prefix(200).description
        }
        if let detail = json["detail"] as? String { return detail }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return nil
    }

    // MARK: - Model selection

    public struct ModelChoice: Sendable, Equatable {
        public var slug: String
        public var effort: String?

        public init(slug: String, effort: String? = nil) {
            self.slug = slug
            self.effort = effort
        }
    }

    /// Models to try, best first: the server's catalog for this account, or — if
    /// that call fails — whatever the local CLI is configured to use.
    static func modelCandidates(
        auth: CodexAuth,
        session: URLSession,
        env: [String: String],
        limit: Int = 3
    ) async -> [ModelChoice] {
        if let catalog = await fetchCatalog(auth: auth, session: session, env: env) {
            let ranked = rank(catalog, planType: auth.planType, limit: limit)
            if !ranked.isEmpty { return ranked }
        }
        if let configured = configuredModel() {
            return [ModelChoice(slug: configured)]
        }
        return []
    }

    static func catalogURL(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base = CodexUsageAPI.baseURLString(env: env) + modelsPath + "?client_version=" + clientVersion
        return URL(string: base) ?? URL(string: CodexUsageAPI.defaultBaseURL + modelsPath)!
    }

    static func fetchCatalog(
        auth: CodexAuth,
        session: URLSession,
        env: [String: String]
    ) async -> ModelCatalog? {
        var request = URLRequest(url: catalogURL(env: env), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexUsageTracker", forHTTPHeaderField: "User-Agent")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        if let accountId = auth.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let catalog = try? JSONDecoder().decode(ModelCatalog.self, from: data) else {
            return nil
        }
        return catalog
    }

    /// Orders the catalog into the models worth trying: user-selectable ones the
    /// account's plan allows, cheapest first.
    static func rank(_ catalog: ModelCatalog, planType: String?, limit: Int = 3) -> [ModelChoice] {
        let named = catalog.models.filter { ($0.slug?.isEmpty == false) }
        // "hide" covers internal models (e.g. codex-auto-review) that a normal
        // client would never select.
        let listed = named.filter { $0.visibility == "list" }
        var usable = listed.isEmpty ? named : listed

        if let plan = planType?.lowercased(), !plan.isEmpty {
            let allowed = usable.filter { model in
                guard let plans = model.availableInPlans, !plans.isEmpty else { return true }
                return plans.contains { $0.lowercased() == plan }
            }
            if !allowed.isEmpty { usable = allowed }
        }

        let cheapFirst = usable.filter(isCheap) + usable.filter { !isCheap($0) }
        return cheapFirst.prefix(limit).map {
            ModelChoice(slug: $0.slug ?? "", effort: cheapestEffort($0))
        }
    }

    private static func isCheap(_ model: ModelCatalog.Model) -> Bool {
        guard let slug = model.slug?.lowercased() else { return false }
        return cheapModelMarkers.contains { slug.contains($0) }
    }

    private static func cheapestEffort(_ model: ModelCatalog.Model) -> String? {
        let supported = (model.supportedReasoningLevels ?? []).compactMap { $0.effort?.lowercased() }
        guard !supported.isEmpty else { return nil }
        return cheapEfforts.first { supported.contains($0) }
    }

    public struct ModelCatalog: Decodable, Sendable {
        public let models: [Model]

        public struct Model: Decodable, Sendable {
            public let slug: String?
            public let visibility: String?
            public let availableInPlans: [String]?
            public let supportedReasoningLevels: [ReasoningLevel]?

            enum CodingKeys: String, CodingKey {
                case slug, visibility
                case availableInPlans = "available_in_plans"
                case supportedReasoningLevels = "supported_reasoning_levels"
            }
        }

        public struct ReasoningLevel: Decodable, Sendable {
            public let effort: String?
        }
    }

    // MARK: - Local CLI config fallback

    /// The `model` the Codex CLI itself is set to use — a model we know this
    /// machine's login can run, for when the catalog call fails.
    static func configuredModel(
        at url: URL = CodexUsageReader.codexHome.appendingPathComponent("config.toml")
    ) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseConfiguredModel(text)
    }

    /// Reads the top-level `model = "…"` out of config.toml. Stops at the first
    /// table header so a `[profiles.x]` override can't be mistaken for the default.
    static func parseConfiguredModel(_ text: String) -> String? {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { return nil }
            guard line.hasPrefix("model") else { continue }
            let afterKey = line.dropFirst("model".count).trimmingCharacters(in: .whitespaces)
            guard afterKey.hasPrefix("=") else { continue }   // model_reasoning_effort etc.
            let value = afterKey.dropFirst().trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("\""), let end = value.dropFirst().firstIndex(of: "\"") else { continue }
            let slug = String(value[value.index(after: value.startIndex)..<end])
            return slug.isEmpty ? nil : slug
        }
        return nil
    }
}
