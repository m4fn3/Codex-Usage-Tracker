//
//  CodexProcessKiller.swift
//  Codex Usage Tracker
//
//  Force-closes running Codex CLI processes (like Codex Switcher's "close all"),
//  so the user can safely switch accounts without a live session holding the old
//  credentials. We identify processes whose executable is the `codex` CLI and
//  signal them, never touching this app itself.
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum CodexProcessKiller {

    public struct Outcome: Sendable, Equatable {
        public let killed: [Int32]
        public let survived: [Int32]
        public var count: Int { killed.count }
    }

    /// Lists PIDs of running Codex CLI processes (excluding this app).
    public static func findCodexPIDs(selfPID: Int32 = getpid()) -> [Int32] {
        guard let output = runPS() else { return [] }
        var pids: [Int32] = []
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.drop { $0 == " " }
            guard let space = line.firstIndex(of: " ") else { continue }
            guard let pid = Int32(line[..<space]) else { continue }
            let command = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
            if pid == selfPID { continue }
            if isCodexCommand(command) { pids.append(pid) }
        }
        return pids
    }

    /// Decides whether a `ps` command line belongs to the Codex CLI.
    ///
    /// Matches the `codex` binary exactly, CASE-SENSITIVELY, like Codex Switcher:
    /// the executable (first whitespace token) is `codex` or ends with `/codex`.
    /// Case sensitivity + the exact suffix keep us from matching ChatGPT.app's
    /// "Codex Framework" helpers, `codex-*` vendored binaries, or this app.
    static func isCodexCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        if lower.contains("codexusagetracker") || lower.contains("codex usage") { return false }
        if lower.contains("codex-switcher") { return false }

        guard let executable = command.split(separator: " ", maxSplits: 1).first else { return false }
        let token = String(executable)
        return token == "codex" || token.hasSuffix("/codex")
    }

    /// Sends SIGTERM, then SIGKILL to any survivors. Returns what happened.
    @discardableResult
    public static func forceCloseAll() -> Outcome {
        let pids = findCodexPIDs()
        guard !pids.isEmpty else { return Outcome(killed: [], survived: []) }

        for pid in pids { _ = kill(pid, SIGTERM) }
        usleep(300_000) // 0.3s grace for a clean exit

        var killed: [Int32] = []
        var survived: [Int32] = []
        for pid in pids {
            if kill(pid, 0) != 0 { killed.append(pid); continue } // already gone
            _ = kill(pid, SIGKILL)
            usleep(50_000)
            if kill(pid, 0) == 0 { survived.append(pid) } else { killed.append(pid) }
        }
        return Outcome(killed: killed, survived: survived)
    }

    private static func runPS() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
