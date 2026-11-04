import AppKit

// Live Claude Code state, copied by ~/.claude/statusline.sh into ~/.gravitty/live/<session>.json (D9).
struct LiveSession {
    var model: String, dir: String
    var pct: Int, ctxSize: Int, tokens: Int
    var cost: Double, durMs: Int
    var rate5: Int?, rate7: Int?
    var agent = Agent.claude, credits: Double? = nil // Kiro meters in credits, not tokens or dollars (D11)
    var updated = Date.distantPast
    var transcript: String?, subagents: [SubAgent] = []
}

enum Usage {
    static let liveDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gravitty/live")

    // Most recently updated sessions of both agents. shortcut: "live" = file touched in the last 10 min, since the
    // statusline only fires on activity; upgrade to a real liveness check with hooks later.
    static func sessions(maxAge: TimeInterval = 600, limit: Int = 3) -> [LiveSession] {
        Array((claudeSessions(maxAge: maxAge) + KiroUsage.sessions(maxAge: maxAge)).sorted { $0.updated > $1.updated }.prefix(limit))
    }

    static func claudeSessions(maxAge: TimeInterval) -> [LiveSession] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: liveDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let recent = urls.filter { $0.pathExtension == "json" }.compactMap { u -> (URL, Date)? in
            guard let d = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Date().timeIntervalSince(d) < maxAge else { return nil }
            return (u, d)
        }.sorted { $0.1 > $1.1 }
        return recent.compactMap { u, d in var s = parse(try? Data(contentsOf: u)); s?.updated = d; if let t = s?.transcript { s?.subagents = SubAgents.running(transcript: t) }; return s }
    }

    static func parse(_ data: Data?) -> LiveSession? {
        guard let data, let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
        let cw = j["context_window"] as? [String: Any] ?? [:]
        let cost = j["cost"] as? [String: Any] ?? [:]
        let rl = j["rate_limits"] as? [String: Any] ?? [:]
        func rate(_ k: String) -> Int? { (rl[k] as? [String: Any])?["used_percentage"].map { Int(num($0)) } }
        let dir = (j["workspace"] as? [String: Any])?["current_dir"] as? String ?? "."
        return LiveSession(
            model: (j["model"] as? [String: Any])?["display_name"] as? String ?? "─",
            dir: (dir as NSString).lastPathComponent,
            pct: min(100, max(0, Int(num(cw["used_percentage"])))),
            ctxSize: Int(num(cw["context_window_size"])),
            tokens: Int(num(cw["total_input_tokens"]) + num(cw["total_output_tokens"])),
            cost: num(cost["total_cost_usd"]), durMs: Int(num(cost["total_duration_ms"])),
            rate5: rate("five_hour"), rate7: rate("seven_day"), transcript: j["transcript_path"] as? String)
    }

    // MARK: formatting (mirrors ~/.claude/statusline.sh, D13)

    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }
    static func duration(_ ms: Int) -> String {
        let s = ms / 1000, h = s / 3600, m = s / 60 % 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))m" : "\(m)m\(s % 60)s"
    }

    static let gradient: [NSColor] = zip(zip([46, 116, 186, 241, 239, 236, 233, 231, 211, 192],
                                             [204, 195, 186, 196, 161, 126, 101, 76, 66, 57]),
                                         [113, 89, 64, 15, 24, 34, 44, 60, 50, 43]).map {
        NSColor(srgbRed: CGFloat($0.0.0) / 255, green: CGFloat($0.0.1) / 255, blue: CGFloat($0.1) / 255, alpha: 1)
    }
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let purple = NSColor(srgbRed: 114 / 255, green: 102 / 255, blue: 234 / 255, alpha: 1)
    static let gray = NSColor(white: 0.55, alpha: 1)

    static func pctColor(_ p: Int) -> NSColor { p >= 90 ? .systemRed : p >= 70 ? .systemYellow : .systemGreen }

    static func strip(_ s: LiveSession) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ t: String, _ c: NSColor) { out.append(NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: c])) }
        let sep = { add(" │ ", gray) }
        add("◆ ", s.agent == .kiro ? Agent.kiro.color : purple); add(s.model, .systemCyan)
        sep()
        appendBar(out, s.pct)
        add(" \(s.pct)%", pctColor(s.pct))
        if s.pct >= 90 { add(" ⚠", .systemRed) }
        if s.ctxSize >= 1_000_000 { add(" 1M", gray) } else if s.ctxSize >= 200_000 { add(" 200k", gray) }
        if let cr = s.credits {
            sep(); add(String(format: "%.2f cr", cr), cr > 0 ? .systemYellow : gray)
        } else {
            sep(); add("\(tokens(s.tokens)) tok", .white)
            sep(); add(String(format: "$%.2f", s.cost), s.cost >= 10 ? .systemRed : s.cost >= 5 ? .systemYellow : s.cost > 0 ? .systemYellow : gray)
        }
        if s.durMs >= 1000 { sep(); add(duration(s.durMs), gray) }
        sep(); add(s.dir, gray)
        return out
    }

    // One short line for the open panel's top band, right of the notch: freshest session plus the 5h plan limit.
    static func compact() -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ t: String, _ c: NSColor) { out.append(NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: c])) }
        guard let s = sessions(limit: 1).first else { add("no active agent sessions", gray); return out }
        add("◆ ", s.agent == .kiro ? Agent.kiro.color : purple); add(s.model, .systemCyan); add(" │ ", gray)
        appendBar(out, s.pct); add(" \(s.pct)%", pctColor(s.pct))
        if let l = limits().five, l.resetsAt > Date() { add(" │ 5h ", gray); add("\(l.pct)%", pctColor(l.pct)) }
        return out
    }

    // Indented row under its session: ↳ type task │ tokens │ elapsed
    static func subagentRow(_ a: SubAgent) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ t: String, _ c: NSColor) { out.append(NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: c])) }
        add("  ↳ ", gray); add(a.type, .systemCyan)
        if !a.task.isEmpty { add(" " + (a.task.count > 32 ? String(a.task.prefix(31)) + "…" : a.task), gray) }
        if let n = a.tokens { add(" │ ", gray); add("\(tokens(n)) tok", .white) }
        if let t = a.startedAt { add(" │ ", gray); add(duration(Int(Date().timeIntervalSince(t) * 1000)), gray) }
        return out
    }

    // One footer for account-wide numbers (rate limits repeat in every session, so show them once).
    static func footer(_ ss: [LiveSession]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ t: String, _ c: NSColor) { out.append(NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: c])) }
        add("\(ss.count) session\(ss.count == 1 ? "" : "s")", gray)
        if ss.contains(where: { $0.credits == nil }) { add(String(format: " │ $%.2f", ss.reduce(0) { $0 + $1.cost }), gray) }
        if ss.contains(where: { $0.credits != nil }) { add(String(format: " │ %.2f cr", ss.reduce(0) { $0 + ($1.credits ?? 0) }), gray) }
        return out
    }

    // Claude Code token totals from the transcripts (Totals.swift); Kiro is metered in credits and not part of it.
    static func totalsLine() -> NSAttributedString {
        let t = Totals.snapshot
        let out = NSMutableAttributedString()
        func add(_ s: String, _ c: NSColor) { out.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c])) }
        add("Σ ", purple); add("today ", gray); add(tokens(t.today), .white)
        add(" │ 7d ", gray); add(tokens(t.week), .white)
        add(" │ all ", gray); add(tokens(t.all), .white); add(" tok", gray)
        return out
    }

    // Kiro credits from the session logs (KiroTotals.swift); empty when Kiro was never used.
    static func kiroTotalsLine() -> NSAttributedString? {
        let t = KiroTotals.snapshot
        guard t.all > 0 else { return nil }
        let out = NSMutableAttributedString()
        func add(_ s: String, _ c: NSColor) { out.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c])) }
        func cr(_ v: Double) -> String { String(format: v >= 100 ? "%.0f" : "%.1f", v) }
        add("Σ ", Agent.kiro.color); add("today ", gray); add(cr(t.today), .white)
        add(" │ 7d ", gray); add(cr(t.week), .white)
        add(" │ all ", gray); add(cr(t.all), .white); add(" cr", gray)
        return out
    }

    static func appendBar(_ out: NSMutableAttributedString, _ pct: Int) {
        let filled = pct / 10
        for i in 0..<10 {
            out.append(NSAttributedString(string: i < filled ? "█" : "░", attributes: [
                .font: font, .foregroundColor: i < filled ? gradient[i] : NSColor(white: 0.24, alpha: 1)]))
        }
    }

    // MARK: Claude plan limits (5-hour and 7-day windows), from the newest statusline copy; account-wide, not per session.

    struct Limit { var pct: Int, resetsAt: Date }

    static func limits() -> (five: Limit?, seven: Limit?) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: liveDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = urls.filter { $0.pathExtension == "json" }.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
        guard let newest, let j = (try? JSONSerialization.jsonObject(with: Data(contentsOf: newest))) as? [String: Any],
              let rl = j["rate_limits"] as? [String: Any] else { return (nil, nil) }
        func limit(_ k: String) -> Limit? {
            guard let w = rl[k] as? [String: Any], let p = w["used_percentage"] as? NSNumber, let r = w["resets_at"] as? NSNumber else { return nil }
            return Limit(pct: min(100, max(0, p.intValue)), resetsAt: Date(timeIntervalSince1970: r.doubleValue))
        }
        return (limit("five_hour"), limit("seven_day"))
    }

    static func untilReset(_ s: TimeInterval) -> String {
        let m = Int(s) / 60
        return m >= 1440 ? "\(m / 1440)d\(m / 60 % 24)h" : m >= 60 ? "\(m / 60)h\(String(format: "%02d", m % 60))m" : "\(max(m, 0))m"
    }

    static func limitsLine() -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ t: String, _ c: NSColor) { out.append(NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: c])) }
        let (five, seven) = limits()
        add("Claude limits", purple)
        for (name, l) in [("5h", five), ("7d", seven)] {
            add(" │ \(name) ", gray)
            guard let l, l.resetsAt > Date() else { add(l == nil ? "─" : "reset", gray); continue } // a passed reset means the number is old
            appendBar(out, l.pct)
            add(" \(l.pct)%", l.pct >= 90 ? .systemRed : l.pct >= 70 ? .systemYellow : .white)
            add(" ↻" + untilReset(l.resetsAt.timeIntervalSinceNow), gray)
        }
        return out
    }

    static func render() -> NSAttributedString {
        let ss = sessions()
        guard !ss.isEmpty else {
            let out = NSMutableAttributedString(string: "no active agent sessions\n", attributes: [.font: font, .foregroundColor: gray])
            out.append(limitsLine()); out.append(NSAttributedString(string: "\n"))
            out.append(totalsLine())
            if let k = kiroTotalsLine() { out.append(NSAttributedString(string: "\n")); out.append(k) }
            return out
        }
        let out = NSMutableAttributedString()
        for s in ss {
            out.append(strip(s)); out.append(NSAttributedString(string: "\n"))
            for a in s.subagents.prefix(3) { out.append(subagentRow(a)); out.append(NSAttributedString(string: "\n")) }
        }
        out.append(footer(ss))
        out.append(NSAttributedString(string: "\n"))
        out.append(limitsLine())
        out.append(NSAttributedString(string: "\n"))
        out.append(totalsLine())
        if let k = kiroTotalsLine() { out.append(NSAttributedString(string: "\n")); out.append(k) }
        return out
    }

    static func selfCheck() {
        assert(tokens(120_011) == "120k" && tokens(999) == "999" && tokens(1_260_000) == "1.3M")
        assert(duration(446_192) == "7m26s" && duration(3_900_000) == "1h05m")
        let j = #"{"model":{"display_name":"S"},"context_window":{"used_percentage":12,"context_window_size":1000000,"total_input_tokens":100,"total_output_tokens":5},"cost":{"total_cost_usd":0.5,"total_duration_ms":1000},"rate_limits":{"five_hour":{"used_percentage":5}},"workspace":{"current_dir":"/a/b"}}"#
        let s = parse(Data(j.utf8))
        KiroUsage.selfCheck()
        assert(untilReset(8100) == "2h15m" && untilReset(200_000) == "2d7h" && untilReset(30) == "0m")
        SubAgents.selfCheck()
        assert(s?.pct == 12 && s?.tokens == 105 && s?.dir == "b" && s?.rate5 == 5 && s?.rate7 == nil)
    }
}
