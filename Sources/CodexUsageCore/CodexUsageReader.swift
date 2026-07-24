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
//        "primary":   { "used_percent": 15.0, "window_minutes": 300,   "resets_at": 1783867252 },
//        "secondary": { "used_percent": 36.0, "window_minutes": 10080, "resets_at": 1784356325 },
//        "plan_type": "plus"
//    }
//
//  Two hard-won facts about this data (verified against real ~/.codex logs) drive
//  the resolution below:
//
//  1. The `primary`/`secondary` slots are NOT stable. Within one file, early lines
//     put the 5-hour session in `primary` and the weekly window in `secondary`,
//     while later lines put the weekly window in `primary` and set `secondary` to
//     null. So the last line of the freshest file frequently carries ONLY the
//     weekly window — the session window silently disappears. We therefore never
//     trust slot position (classify by `window_minutes`) and we never look at only
//     the last line (we resolve the freshest observation of EACH window across all
//     recent lines).
//
//  2. Codex only refreshes `rate_limits` when the CLI makes a request, and it can
//     replay a stale snapshot whose `resets_at` is already in the past or whose
//     usage is lower than a concurrent session's. So the current window is the one
//     with the furthest-future reset boundary, and its usage is the MAX reported
//     within that boundary (a lower late reading is stale, not a real restore).
//

import Foundation

public enum CodexUsageReader {

    /// Root of the Codex CLI data directory. Honors `CODEX_HOME` if set.
    public static var codexHome: URL {
        if let dir = ProcessInfo.processInfo.environment["CODEX_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    public static var sessionsDirectory: URL {
        codexHome.appendingPathComponent("sessions")
    }

    /// Loads the freshest usage snapshot, scanning the `maxFiles` most recently
    /// modified rollout files. Returns nil when no rate-limit data exists yet.
    ///
    /// `preferredPlan` scopes resolution to a specific plan (e.g. the plan of the
    /// account currently logged in per auth.json). This is what keeps a stale,
    /// freshly-modified session from a *different* account (a different plan) from
    /// hijacking the reading. Without it, the newest observation's plan wins.
    public static func loadLatest(
        maxFiles: Int = 40,
        preferredPlan: String? = nil,
        now: Date = Date()
    ) -> CodexUsage? {
        var observations: [RateObservation] = []
        for url in recentRolloutFiles(limit: maxFiles) {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            observations.append(contentsOf: fileObservations(fromContent: content))
        }
        return resolve(observations: observations, preferredPlan: preferredPlan, now: now)
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

    // MARK: - Resolution

    /// One reported window at one point in time.
    struct RateObservation: Equatable {
        var timestamp: Date
        var role: WindowRole
        var usedPercent: Double
        var windowMinutes: Int
        var resetsAt: Date?
        var planType: String?
    }

    /// Two reset boundaries within this many seconds are treated as the same
    /// window (Codex jitters `resets_at` by ~1 second between lines). Real
    /// distinct windows are ≥ 5 hours apart, so this can't merge two windows.
    static let boundaryTolerance: TimeInterval = 120

    /// Resolves the raw observations into a snapshot: the freshest state of each
    /// window role, with false-restore protection.
    static func resolve(
        observations: [RateObservation],
        preferredPlan: String? = nil,
        now: Date
    ) -> CodexUsage? {
        // Prefer the caller's plan (the logged-in account's), else fall back to the
        // newest observation's plan. Scoping to one plan stops a stale account of a
        // different plan from polluting a role — e.g. a free 30-day window and a
        // paid weekly window both classify as `.weekly`.
        let newestOverall = observations.max { $0.timestamp < $1.timestamp }
        let plan = preferredPlan ?? newestOverall?.planType
        let scoped = plan == nil ? observations : observations.filter { $0.planType == plan }

        let session = resolveWindow(scoped.filter { $0.role == .session })
        let weekly = resolveWindow(scoped.filter { $0.role == .weekly })
        guard session != nil || weekly != nil else { return nil }

        // "Last updated" is the newest observation within the resolved plan.
        let lastUpdated = scoped.max { $0.timestamp < $1.timestamp }?.timestamp
            ?? newestOverall?.timestamp ?? now

        return CodexUsage(
            session: session,
            weekly: weekly,
            planType: plan,
            lastUpdated: lastUpdated,
            source: .localFiles
        )
    }

    /// Collapses all observations of one role into the single current window.
    static func resolveWindow(_ observations: [RateObservation]) -> CodexRateWindow? {
        guard !observations.isEmpty else { return nil }

        let boundaries = observations.compactMap(\.resetsAt)
        guard let boundary = boundaries.max() else {
            // No reset info anywhere — trust the newest reading as-is.
            let newest = observations.max { $0.timestamp < $1.timestamp }!
            return CodexRateWindow(
                usedPercent: newest.usedPercent,
                windowMinutes: newest.windowMinutes,
                resetsAt: nil
            )
        }

        // The current window is the furthest-future boundary; older boundaries are
        // superseded windows (or stale replays) and are ignored.
        let current = observations.filter {
            guard let r = $0.resetsAt else { return false }
            return abs(r.timeIntervalSince(boundary)) <= boundaryTolerance
        }
        // Usage can only climb within a fixed window, so the MAX reading is the
        // truth; a lower late reading is a stale replay, not a real restore.
        let used = current.map(\.usedPercent).max() ?? 0
        let newestInWindow = current.max { $0.timestamp < $1.timestamp } ?? current[0]

        return CodexRateWindow(
            usedPercent: used,
            windowMinutes: newestInWindow.windowMinutes,
            resetsAt: boundary
        )
    }

    // MARK: - Parsing

    /// Reduces one file's `rate_limits` lines to one observation per
    /// (role, reset boundary): the newest reading for that boundary, carrying the
    /// peak usage seen at it. Keeping distinct boundaries separate (rather than
    /// collapsing to one per role) lets `resolveWindow` apply the jitter tolerance
    /// consistently; the peak-usage merge stops an intra-file stale-lower replay
    /// from lowering a boundary we've already seen higher.
    static func fileObservations(fromContent content: String) -> [RateObservation] {
        struct Key: Hashable { let role: WindowRole; let boundary: Int }
        var byKey: [Key: RateObservation] = [:]

        for line in content.split(separator: "\n", omittingEmptySubsequences: true)
        where line.contains("\"rate_limits\"") {
            for obs in parse(line: String(line)) {
                let key = Key(
                    role: obs.role,
                    boundary: obs.resetsAt.map { Int($0.timeIntervalSince1970.rounded()) } ?? Int.min
                )
                guard var merged = byKey[key] else {
                    byKey[key] = obs
                    continue
                }
                merged.usedPercent = max(merged.usedPercent, obs.usedPercent)
                if obs.timestamp > merged.timestamp {
                    merged.timestamp = obs.timestamp
                    merged.windowMinutes = obs.windowMinutes
                    merged.planType = obs.planType
                }
                byKey[key] = merged
            }
        }
        return Array(byKey.values)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseTimestamp(_ string: String) -> Date? {
        isoFormatter.date(from: string) ?? isoFormatterNoFraction.date(from: string)
    }

    /// Parses one JSONL line into its per-role window observations (0, 1, or 2).
    static func parse(line: String) -> [RateObservation] {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestampString = root["timestamp"] as? String,
              let timestamp = parseTimestamp(timestampString),
              let payload = root["payload"] as? [String: Any],
              let rateLimits = payload["rate_limits"] as? [String: Any] else {
            return []
        }
        let planType = rateLimits["plan_type"] as? String

        var result: [RateObservation] = []
        for slot in ["primary", "secondary"] {
            guard let window = window(from: rateLimits[slot], timestamp: timestamp, planType: planType) else { continue }
            result.append(window)
        }
        return result
    }

    private static func window(from any: Any?, timestamp: Date, planType: String?) -> RateObservation? {
        guard let dict = any as? [String: Any],
              let used = (dict["used_percent"] as? NSNumber)?.doubleValue,
              let minutes = (dict["window_minutes"] as? NSNumber)?.intValue,
              let role = WindowRole.classify(windowMinutes: minutes) else { return nil }

        let resetsRaw = (dict["resets_at"] as? NSNumber)?.doubleValue ?? 0
        let resetsAt: Date? = resetsRaw > 0 ? Date(timeIntervalSince1970: resetsRaw) : nil

        return RateObservation(
            timestamp: timestamp,
            role: role,
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: resetsAt,
            planType: planType
        )
    }
}
