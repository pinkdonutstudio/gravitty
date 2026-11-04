import Foundation

struct SubAgent { var type: String, task: String, tokens: Int?, startedAt: Date? } // tokens nil = not recorded (Kiro)

// Running Claude Code sub-agents of a session: <session>/subagents/agent-<id>.jsonl (+ .meta.json).
// Tokens are summed incrementally, like KiroUsage. Kiro v3 sub-agents are not covered (format not checked).
enum SubAgents {
    struct State { var offset: UInt64 = 0, tokens = 0; var startedAt: Date? }
    nonisolated(unsafe) private static var cache: [String: State] = [:] // main thread only

    /// Billed-ish tokens: new input + cache writes + output (cache reads would count the same context over and over).
    static func fold(_ text: String, into st: inout State) -> Int {
        guard let end = text.lastIndex(of: "\n") else { return 0 }
        for line in text[..<end].split(separator: "\n") {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if st.startedAt == nil, let t = o["timestamp"] as? String { st.startedAt = ISO8601DateFormatter.withFraction.date(from: t) }
            if let u = (o["message"] as? [String: Any])?["usage"] as? [String: Any] {
                for k in ["input_tokens", "cache_creation_input_tokens", "output_tokens"] { st.tokens += (u[k] as? NSNumber)?.intValue ?? 0 }
            }
        }
        return text[...end].utf8.count
    }

    static func running(transcript: String?, maxAge: TimeInterval = 600) -> [SubAgent] {
        guard let transcript, transcript.hasSuffix(".jsonl") else { return [] }
        let dir = URL(fileURLWithPath: String(transcript.dropLast(6)) + "/subagents")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "jsonl" }.compactMap { f in
            guard let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Date().timeIntervalSince(m) < maxAge,
                  let tail = Activity.tail(of: f.path), Activity.turnOpen(tail: tail, sidechain: true),
                  let h = FileHandle(forReadingAtPath: f.path) else { return nil }
            defer { try? h.close() }
            var st = cache[f.path] ?? State()
            try? h.seek(toOffset: st.offset)
            if let data = try? h.readToEnd() { st.offset += UInt64(fold(String(decoding: data, as: UTF8.self), into: &st)) }
            cache[f.path] = st
            let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: f.deletingPathExtension().appendingPathExtension("meta.json")))) as? [String: Any]
            return SubAgent(type: meta?["agentType"] as? String ?? "agent", task: meta?["description"] as? String ?? "",
                            tokens: st.tokens, startedAt: st.startedAt)
        }.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    }

    static func selfCheck() {
        let a = #"{"timestamp":"2026-11-03T10:00:00.000Z","message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":10,"cache_read_input_tokens":9999,"output_tokens":5}}}"#
        var st = State()
        let used = fold(a + "\n" + a + "\n{half", into: &st)
        assert(st.tokens == 34 && st.startedAt != nil && used == (a + "\n" + a + "\n").utf8.count)
    }
}
