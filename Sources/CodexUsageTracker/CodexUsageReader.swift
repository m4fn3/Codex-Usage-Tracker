//
//  CodexUsageReader.swift
//  Codex Usage Tracker
//
//  Reads Codex usage from the local Codex CLI data directory (~/.codex).
//  Codex writes session "rollout" JSONL files under ~/.codex/sessions/YYYY/MM/DD/.
//  Each API turn appends an `event_msg` of type `token_count` whose payload
//  carries a `rate_limits` object:
//
//    "rate_limits": {
//        "primary":   { "used_percent": 90.0, "window_minutes": 300,   "resets_at": 1783176273 },
//        "secondary": { "used_percent": 19.0, "window_minutes": 10080, "resets_at": 1783410496 },
//        "plan_type": "plus"
//    }
//
//  `primary` is the 5-hour session window; `secondary` is the weekly window.
//  The freshest snapshot lives in whichever recent file has the newest such entry
//  (the most-recently-*modified* session may be idle and contain none), so we scan
//  the newest few files and keep the entry with the largest timestamp.
//

import Foundation

enum CodexUsageReader {

    /// Root of the Codex CLI data directory. Honors `CODEX_HOME` if set.
    static var codexHome: URL {
        if let dir = ProcessInfo.processInfo.environment["CODEX_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static var sessionsDirectory: URL {
        codexHome.appendingPathComponent("sessions")
    }

    /// Loads the freshest usage snapshot, scanning the `maxFiles` most recently
    /// modified rollout files. Returns nil when no rate-limit data exists yet.
    static func loadLatest(maxFiles: Int = 25) -> CodexUsage? {
        var best: (ts: String, usage: CodexUsage)?
        for url in recentRolloutFiles(limit: maxFiles) {
            guard let found = latestRateLimit(in: url) else { continue }
            if best == nil || found.ts > best!.ts {
                best = found
            }
        }
        return best?.usage
    }

    // MARK: - File discovery

    private static func recentRolloutFiles(limit: Int) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-") else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            files.append((url, modified))
        }
        return files
            .sorted { $0.modified > $1.modified }
            .prefix(limit)
            .map(\.url)
    }

    // MARK: - Parsing

    /// Returns the newest `rate_limits` record within a single file, if any.
    private static func latestRateLimit(in url: URL) -> (ts: String, usage: CodexUsage)? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        // Lines are appended chronologically, so the last matching line is newest.
        var lastMatch: Substring?
        for line in content.split(separator: "\n", omittingEmptySubsequences: true)
        where line.contains("\"rate_limits\"") {
            lastMatch = line
        }
        guard let line = lastMatch else { return nil }
        return parse(line: String(line))
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parse(line: String) -> (ts: String, usage: CodexUsage)? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = root["timestamp"] as? String,
              let payload = root["payload"] as? [String: Any],
              let rateLimits = payload["rate_limits"] as? [String: Any],
              let primary = window(from: rateLimits["primary"]) else {
            return nil
        }

        // Weekly may occasionally be absent; fall back to the primary window so the
        // UI still renders rather than dropping the whole snapshot.
        let weekly = window(from: rateLimits["secondary"]) ?? primary
        let planType = rateLimits["plan_type"] as? String
        let updated = isoFormatter.date(from: timestamp)
            ?? ISO8601DateFormatter().date(from: timestamp)
            ?? Date()

        let usage = CodexUsage(
            session: primary,
            weekly: weekly,
            planType: planType,
            lastUpdated: updated
        )
        return (timestamp, usage)
    }

    private static func window(from any: Any?) -> CodexRateWindow? {
        guard let dict = any as? [String: Any],
              let used = (dict["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let minutes = (dict["window_minutes"] as? NSNumber)?.intValue ?? 0
        let resetsAt = (dict["resets_at"] as? NSNumber)?.doubleValue ?? 0
        return CodexRateWindow(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: Date(timeIntervalSince1970: resetsAt)
        )
    }
}
