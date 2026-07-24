//
//  CodexUsageProvider.swift
//  Codex Usage Tracker
//
//  Top-level entry point the app calls to get usage. It prefers the live API for
//  the currently logged-in account (authoritative and always the right account),
//  and falls back to the local rollout files — scoped to that account's plan — when
//  the API can't be reached or there's no auth.
//

import Foundation

public enum CodexUsageProvider {

    /// Resolves the best available usage snapshot for the current account.
    public static func load(now: Date = Date()) async -> CodexUsage? {
        let auth = CodexAuth.load()

        // 1. Live API for the logged-in account — the correct source of truth.
        if let auth, auth.isAccessTokenValid(now: now) {
            do {
                if let usage = try await CodexUsageAPI.fetch(auth: auth, now: now) {
                    return usage
                }
                // 200 but no windows (e.g. unlimited plan) → try local as a backstop.
            } catch {
                // Network/unauthorized/parse failure → fall through to local files.
            }
        }

        // 2. Local rollout files, scoped to the current account's plan when known.
        //    Scan more files here since the account's freshest data may sit behind
        //    other accounts' recently-touched sessions.
        let usage = CodexUsageReader.loadLatest(
            maxFiles: auth != nil ? 200 : 40,
            preferredPlan: auth?.planType,
            now: now
        )

        // Tag the fallback with the account identity we know from auth.json.
        guard var usage, let auth else { return usage }
        if usage.accountId == nil { usage.accountId = auth.accountId }
        if usage.accountEmail == nil { usage.accountEmail = auth.email }
        return usage
    }
}
