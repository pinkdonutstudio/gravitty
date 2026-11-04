import Foundation

// Per-session Kiro v3 numbers (D11): context % and credits, folded from ~/.kiro/sessions/<ws>/sess_<id>/messages.jsonl.
// The log only grows, so each session keeps a byte offset and just the new lines are read on every refresh.
enum KiroUsage {
    struct State { var offset: UInt64 = 0, credits = 0.0, ctx = 0.0; var running: [String: SubAgent] = [:] } // running: by subSessionId
    nonisolated(unsafe) private static var cache: [String: State] = [:] // main thread only

    /// Folds complete lines into the state; returns how many bytes it consumed (a half-written last line is left for next time).
    static func fold(_ text: String, into st: inout State) -> Int {
        guard let end = text.lastIndex(of: "\n") else { return 0 }
        for line in text[..<end].split(separator: "\n") {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let p = o["payload"] as? [String: Any] else { continue }
            switch p["type"] as? String {
            case "usage_summary":
                for t in p["promptTurnSummaries"] as? [[String: Any]] ?? [] { st.credits += (t["usage"] as? NSNumber)?.doubleValue ?? 0 }
            case "session_metadata" where p["key"] as? String == "contextUsage":
                st.ctx = ((p["value"] as? [String: Any])?["usagePercentage"] as? NSNumber)?.doubleValue ?? st.ctx
            case "sub_agent_start":
                let task = (p["prompt"] as? String ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
                st.running[p["subSessionId"] as? String ?? UUID().uuidString] = SubAgent(
                    type: p["subAgentName"] as? String ?? "agent", task: String(task.prefix(60)), tokens: nil,
                    startedAt: (o["timestamp"] as? String).flatMap { ISO8601DateFormatter.withFraction.date(from: $0) })
            case "sub_agent_complete": st.running[p["subSessionId"] as? String ?? ""] = nil
            case "turn_end": st.running.removeAll() // a finished turn leaves nothing running, even if a completion was never logged
            default: break
            }
        }
        return text[...end].utf8.count
    }

    static func sessions(maxAge: TimeInterval) -> [LiveSession] {
        Activity.kiroSessions(maxAge: maxAge).compactMap { s in
            guard let j = (try? JSONSerialization.jsonObject(with: Data(contentsOf: s.dir.appendingPathComponent("session.json")))) as? [String: Any],
                  let h = FileHandle(forReadingAtPath: s.log.path) else { return nil }
            defer { try? h.close() }
            var st = cache[s.log.path] ?? State()
            try? h.seek(toOffset: st.offset)
            if let data = try? h.readToEnd() { st.offset += UInt64(fold(String(decoding: data, as: UTF8.self), into: &st)) }
            cache[s.log.path] = st

            let id = j["modelId"] as? String ?? "─"
            let created = (j["createdAt"] as? String).flatMap { ISO8601DateFormatter.withFraction.date(from: $0) }
            return LiveSession(model: id == "auto" ? "Auto" : id,
                               dir: ((j["workspacePaths"] as? [String])?.first as NSString?)?.lastPathComponent ?? ".",
                               pct: min(100, max(0, Int(st.ctx))), ctxSize: 0, tokens: 0, cost: 0,
                               durMs: created.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0,
                               rate5: nil, rate7: nil, agent: .kiro, credits: st.credits, updated: s.updated,
                               subagents: st.running.values.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) })
        }
    }

    static func selfCheck() {
        let a = #"{"payload":{"type":"usage_summary","promptTurnSummaries":[{"usage":0.1},{"usage":0.2}]}}"#
        let b = #"{"payload":{"type":"session_metadata","key":"contextUsage","value":{"usagePercentage":3.6}}}"#
        var st = State()
        let used = fold(a + "\n" + b + "\n{half", into: &st) // the unfinished last line must not be consumed
        assert(abs(st.credits - 0.3) < 1e-9 && st.ctx == 3.6 && used == (a + "\n" + b + "\n").utf8.count)
        let s1 = #"{"timestamp":"2026-11-03T10:00:00.000Z","payload":{"type":"sub_agent_start","subSessionId":"x","subAgentName":"context-gatherer","prompt":"look\nhere"}}"#
        let s2 = #"{"timestamp":"2026-11-03T10:00:00.000Z","payload":{"type":"sub_agent_start","subSessionId":"y","subAgentName":"other","prompt":"p"}}"#
        let done = #"{"payload":{"type":"sub_agent_complete","subSessionId":"x"}}"#, end = #"{"payload":{"type":"turn_end"}}"#
        var k = State()
        _ = fold([s1, s2, done].joined(separator: "\n") + "\n", into: &k)
        assert(k.running.count == 1 && k.running["y"]?.type == "other")
        _ = fold([s1, end].joined(separator: "\n") + "\n", into: &k)
        assert(k.running.isEmpty)
    }
}

extension ISO8601DateFormatter {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
