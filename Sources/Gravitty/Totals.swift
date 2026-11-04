import Foundation

// Claude Code token totals (today / last 7 days / all time) from every transcript under ~/.claude/projects,
// sub-agent logs included. Scanned on a background queue: everything at launch, then only the new bytes of each file.
// A message is written once per content block, so lines are deduplicated by message id + request id (keeping the largest usage).
// shortcut: no on-disk cache, so launch rescans everything (~0.5 s for 300 MB); add one when that gets noticeable.
enum Totals {
    struct Snapshot { var today = 0, week = 0, all = 0 }
    typealias Messages = [String: (at: Date, tokens: Int)]

    nonisolated(unsafe) private static var snap = Snapshot()
    nonisolated(unsafe) private static var offsets: [String: UInt64] = [:]
    nonisolated(unsafe) private static var msgs: Messages = [:]
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "gravitty.totals", qos: .utility)

    static var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return snap }

    static func refresh() { queue.async { scan() } }

    private static func scan() {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return }
        for case let u as URL in en where u.pathExtension == "jsonl" {
            let size = UInt64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            var off = offsets[u.path] ?? 0
            if size < off { off = 0 } // rewritten file; the dedup makes a re-read harmless
            guard size > off, let h = FileHandle(forReadingAtPath: u.path) else { continue }
            defer { try? h.close() }
            try? h.seek(toOffset: off)
            guard let data = try? h.readToEnd() else { continue }
            offsets[u.path] = off + UInt64(fold(String(decoding: data, as: UTF8.self), into: &msgs))
        }
        let start = Calendar.current.startOfDay(for: Date()), weekAgo = Date().addingTimeInterval(-7 * 86400)
        var s = Snapshot()
        for m in msgs.values {
            s.all += m.tokens
            if m.at >= weekAgo { s.week += m.tokens }
            if m.at >= start { s.today += m.tokens }
        }
        lock.lock(); snap = s; lock.unlock()
    }

    /// Tokens = new input + cache writes + output (D21). Returns the bytes consumed; a half-written last line is left alone.
    static func fold(_ text: String, into msgs: inout Messages) -> Int {
        guard let end = text.lastIndex(of: "\n") else { return 0 }
        for line in text[..<end].split(separator: "\n") where line.contains("\"usage\"") {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], o["type"] as? String == "assistant",
                  let m = o["message"] as? [String: Any], let u = m["usage"] as? [String: Any],
                  let at = (o["timestamp"] as? String).flatMap({ ISO8601DateFormatter.withFraction.date(from: $0) }) else { continue }
            let t = ["input_tokens", "cache_creation_input_tokens", "output_tokens"].reduce(0) { $0 + ((u[$1] as? NSNumber)?.intValue ?? 0) }
            let key = "\(m["id"] as? String ?? UUID().uuidString)|\(o["requestId"] as? String ?? "")"
            if t > (msgs[key]?.tokens ?? -1) { msgs[key] = (at, t) }
        }
        return text[...end].utf8.count
    }

    static func selfCheck() {
        let a = #"{"type":"assistant","timestamp":"2026-11-03T10:00:00.000Z","requestId":"r1","message":{"id":"m1","usage":{"input_tokens":2,"output_tokens":1}}}"#
        let a2 = #"{"type":"assistant","timestamp":"2026-11-03T10:00:01.000Z","requestId":"r1","message":{"id":"m1","usage":{"input_tokens":2,"output_tokens":9}}}"#
        let b = #"{"type":"assistant","timestamp":"2026-11-03T10:00:02.000Z","requestId":"r2","message":{"id":"m2","usage":{"output_tokens":4,"cache_read_input_tokens":999}}}"#
        let user = #"{"type":"user","message":{"usage":{"output_tokens":500}}}"#
        var m = Messages()
        let used = fold([a, a2, b, user].joined(separator: "\n") + "\n{half", into: &m)
        assert(m.count == 2 && m.values.reduce(0) { $0 + $1.tokens } == 11 + 4 && used == ([a, a2, b, user].joined(separator: "\n") + "\n").utf8.count)
    }
}
