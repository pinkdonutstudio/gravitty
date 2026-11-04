import Foundation

// Kiro CLI v3 credit totals (today / last 7 days / all time) from every session log under ~/.kiro/sessions.
// Same approach as Totals.swift: background queue, only the new bytes of each file, deduplicated by event id.
// Only `usage_summary` events are read. Kiro meters in credits, never dollars (D23). The old flat `cli/` dir is v2: ignored.
enum KiroTotals {
    struct Snapshot { var today = 0.0, week = 0.0, all = 0.0 }
    typealias Events = [String: (at: Date, credits: Double)]

    nonisolated(unsafe) private static var snap = Snapshot()
    nonisolated(unsafe) private static var offsets: [String: UInt64] = [:]
    nonisolated(unsafe) private static var events: Events = [:]
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "gravitty.kirototals", qos: .utility)

    static var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return snap }

    static func refresh() { queue.async { scan() } }

    private static func scan() {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".kiro/sessions")
        for ws in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where ws.lastPathComponent != "cli" {
            for s in (try? fm.contentsOfDirectory(at: ws, includingPropertiesForKeys: nil)) ?? [] where s.lastPathComponent.hasPrefix("sess_") {
                let log = s.appendingPathComponent("messages.jsonl")
                let size = UInt64((try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                var off = offsets[log.path] ?? 0
                if size < off { off = 0 } // rewritten file; the dedup makes a re-read harmless
                guard size > off, let h = FileHandle(forReadingAtPath: log.path) else { continue }
                defer { try? h.close() }
                try? h.seek(toOffset: off)
                guard let data = try? h.readToEnd() else { continue }
                offsets[log.path] = off + UInt64(fold(String(decoding: data, as: UTF8.self), into: &events))
            }
        }
        let start = Calendar.current.startOfDay(for: Date()), weekAgo = Date().addingTimeInterval(-7 * 86400)
        var s = Snapshot()
        for e in events.values {
            s.all += e.credits
            if e.at >= weekAgo { s.week += e.credits }
            if e.at >= start { s.today += e.credits }
        }
        lock.lock(); snap = s; lock.unlock()
    }

    /// Returns the bytes consumed; a half-written last line is left for next time.
    static func fold(_ text: String, into events: inout Events) -> Int {
        guard let end = text.lastIndex(of: "\n") else { return 0 }
        for line in text[..<end].split(separator: "\n") where line.contains("usage_summary") {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let id = o["id"] as? String, let p = o["payload"] as? [String: Any], p["type"] as? String == "usage_summary",
                  let at = (o["timestamp"] as? String).flatMap({ ISO8601DateFormatter.withFraction.date(from: $0) }) else { continue }
            let c = (p["promptTurnSummaries"] as? [[String: Any]] ?? []).reduce(0.0) { $0 + (($1["usage"] as? NSNumber)?.doubleValue ?? 0) }
            events[id] = (at, c)
        }
        return text[...end].utf8.count
    }

    static func selfCheck() {
        let a = #"{"id":"e1","timestamp":"2026-11-03T10:00:00.000Z","payload":{"type":"usage_summary","promptTurnSummaries":[{"usage":0.5},{"usage":0.25}]}}"#
        let other = #"{"id":"e2","timestamp":"2026-11-03T10:00:01.000Z","payload":{"type":"turn_end"}}"#
        var ev = Events()
        let used = fold([a, other, a].joined(separator: "\n") + "\n{half", into: &ev) // repeated id counts once
        assert(ev.count == 1 && ev["e1"]?.credits == 0.75 && used == ([a, other, a].joined(separator: "\n") + "\n").utf8.count)
    }
}
