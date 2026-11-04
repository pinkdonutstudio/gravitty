import AppKit

enum Agent: CaseIterable {
    case claude, kiro
    var color: NSColor {
        self == .claude ? NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1) // Claude orange
                        : NSColor(srgbRed: 0x90 / 255, green: 0x46 / 255, blue: 0xFF / 255, alpha: 1) // Kiro purple
    }
}

// Which agents are working right now, for the notch glow. Polled once a second. Claude uses hook state files when the
// hooks are installed (Onboarding.hooksInstalled), otherwise the transcript alone.
enum Activity {
    static func working() -> [Agent] { Agent.allCases.filter { $0 == .claude ? claudeWorking() : kiroWorking() } }

    // MARK: Claude: the last user/assistant line of each live session's transcript says whether a turn is open.

    static func claudeWorking() -> Bool {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Usage.liveDir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.contains { u in
            guard let j = (try? JSONSerialization.jsonObject(with: Data(contentsOf: u))) as? [String: Any],
                  let path = j["transcript_path"] as? String,
                  let mtime = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  let tail = tail(of: path) else { return false }
            let age = Date().timeIntervalSince(mtime)
            let sf = stateDir.appendingPathComponent(u.deletingPathExtension().lastPathComponent)
            let state = try? String(contentsOf: sf, encoding: .utf8)
            let stateAge = (try? sf.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) } ?? .infinity
            return hookWorking(state: state, age: age, stateAge: stateAge, turnOpen: turnOpen(tail: tail))
        }
    }

    /// Did this agent stop for real? With Claude hooks, Esc or a timeout leaves "working" behind, so only a fresh "idle"
    /// from the Stop hook counts. Kiro, and Claude without hooks, always count.
    static func finishedCleanly(_ a: Agent) -> Bool {
        guard a == .claude else { return true }
        let files = (try? FileManager.default.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = files.compactMap { f in (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (f, $0) } }
        guard let newest = dated.max(by: { $0.1 < $1.1 }) else { return true }
        return Date().timeIntervalSince(newest.1) < 5 && (try? String(contentsOf: newest.0, encoding: .utf8)) == "idle"
    }

    static let stateDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gravitty/state")

    /// Hook states: "working" (prompt sent, or a tool just finished), "tool" (a tool is running), "idle" (Stop / SessionEnd).
    /// Esc sends no Stop hook, and pressing it before the first reply leaves no mark in the transcript either, so "working"
    /// with no activity (hook or transcript write) for 3 min counts as idle. A running tool may legitimately be quiet for
    /// up to 1 h. shortcut: two tools in flight at once look like "working" after the first one ends.
    /// Without hooks (state == nil): an open turn counts only while the transcript changed in the last 10 min.
    static func hookWorking(state: String?, age: TimeInterval, stateAge: TimeInterval, turnOpen: Bool) -> Bool {
        guard let state else { return age < 600 && turnOpen }
        guard turnOpen else { return false }
        switch state {
        case "tool": return min(age, stateAge) < 3600
        case "working": return min(age, stateAge) < 180
        default: return false
        }
    }

    static func tail(of path: String, bytes: UInt64 = 65536) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > bytes ? size - bytes : 0)
        return (try? h.readToEnd()).flatMap { String(decoding: $0, as: UTF8.self) }
    }

    /// Open turn = last user/assistant line is a prompt, a tool result, or an assistant message that has not ended.
    static func turnOpen(tail: String, sidechain: Bool = false) -> Bool { // sidechain: read a sub-agent's own log
        for line in tail.split(separator: "\n").reversed() {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let t = o["type"] as? String, t == "user" || t == "assistant", (o["isSidechain"] as? Bool == true) == sidechain else { continue }
            if line.contains("Request interrupted") { return false }
            if t == "user" { return true }
            let stop = (o["message"] as? [String: Any])?["stop_reason"] as? String
            return stop == nil || stop == "tool_use"
        }
        return false
    }

    // MARK: Kiro v3: ~/.kiro/sessions/<workspace>/sess_<id>/messages.jsonl logs explicit turn_start / turn_end events,
    // and a .lock file holds the pid of the process that owns the session. (The old flat `cli/` dir is the v2 engine: ignored.)

    /// Kiro v3 sessions whose log changed within `maxAge` seconds and whose owning process is alive.
    static func kiroSessions(maxAge: TimeInterval = 600) -> [(dir: URL, log: URL, updated: Date)] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".kiro/sessions")
        var out: [(URL, URL, Date)] = []
        for ws in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where ws.lastPathComponent != "cli" {
            for s in (try? fm.contentsOfDirectory(at: ws, includingPropertiesForKeys: nil)) ?? [] where s.lastPathComponent.hasPrefix("sess_") {
                let log = s.appendingPathComponent("messages.jsonl")
                guard let m = try? log.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      Date().timeIntervalSince(m) < maxAge, lockAlive(s) else { continue }
                out.append((s, log, m))
            }
        }
        return out
    }

    static func kiroWorking() -> Bool {
        kiroSessions().contains { s in tail(of: s.log.path).map(kiroTurnOpen(tail:)) ?? false }
    }

    static func lockAlive(_ session: URL) -> Bool {
        guard let d = try? Data(contentsOf: session.appendingPathComponent(".lock")),
              let pid = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["pid"] as? Int else { return false }
        return kill(pid_t(pid), 0) == 0
    }

    static func kiroTurnOpen(tail: String) -> Bool {
        for line in tail.split(separator: "\n").reversed() {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let t = (o["payload"] as? [String: Any])?["type"] as? String else { continue }
            if t == "turn_start" { return true }
            if t == "turn_end" { return false }
        }
        return false
    }

    static func selfCheck() {
        assert(hookWorking(state: nil, age: 10, stateAge: 0, turnOpen: true) && !hookWorking(state: nil, age: 700, stateAge: 0, turnOpen: true))
        assert(hookWorking(state: "working", age: 1200, stateAge: 20, turnOpen: true))  // hook fired recently
        assert(!hookWorking(state: "working", age: 400, stateAge: 400, turnOpen: true)) // Esc before any reply
        assert(!hookWorking(state: "working", age: 10, stateAge: 10, turnOpen: false) && !hookWorking(state: "idle", age: 10, stateAge: 10, turnOpen: true))
        assert(hookWorking(state: "tool", age: 1200, stateAge: 1200, turnOpen: true) && !hookWorking(state: "tool", age: 4000, stateAge: 4000, turnOpen: true))
        let user = #"{"type":"user","message":{"content":"hi"}}"#
        let tool = #"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#
        let end = #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#
        let noise = #"{"type":"last-prompt"}"#
        let side = #"{"type":"assistant","isSidechain":true,"message":{"stop_reason":"tool_use"}}"#
        let stop = #"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        assert(turnOpen(tail: [user].joined(separator: "\n")))
        assert(turnOpen(tail: [user, tool, noise].joined(separator: "\n")))
        assert(!turnOpen(tail: [user, tool, end, noise].joined(separator: "\n")))
        assert(!turnOpen(tail: [user, end, side].joined(separator: "\n")))
        assert(!turnOpen(tail: [user, tool, stop].joined(separator: "\n")))
        assert(!turnOpen(tail: "{broken"))
        assert(turnOpen(tail: [user, side].joined(separator: "\n").replacingOccurrences(of: #"{"type":"user""#, with: #"{"type":"user","isSidechain":true"#), sidechain: true))
        assert(!turnOpen(tail: side, sidechain: false))
        let ks = #"{"payload":{"type":"turn_start"}}"#, ke = #"{"payload":{"type":"turn_end"}}"#, ku = #"{"payload":{"type":"usage_summary"}}"#
        assert(kiroTurnOpen(tail: [ks, ku].joined(separator: "\n")))
        assert(!kiroTurnOpen(tail: [ks, ku, ke, ku].joined(separator: "\n")))
        assert(!kiroTurnOpen(tail: "") && !kiroTurnOpen(tail: "{broken"))
    }
}
