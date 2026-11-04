import AppKit

/// Dark-teal falling-glyph intro, played over the terminal area on every new tab and on the first panel open after launch (D31).
/// shortcut: redraws every cell each frame with NSString.draw; fine for ~2 s, switch to cached glyph layers if it ever runs longer.
final class Rain: NSView {
    private struct Col { var head: Double; var speed: Double; var glyphs: [Character] }
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let cellW: CGFloat = 12, cellH: CGFloat = 16, trail = 14
    private let pool = Array("01<>/\\|{}[]#$%&*+=ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄ")
    private var cols: [Col] = []
    private var timer: Timer?
    private var start = Date()
    private let total = 2.4, fade = 0.7

    override func hitTest(_ p: NSPoint) -> NSView? { nil } // never steals clicks from the terminal

    static func play(over parent: NSView) {
        parent.subviews.compactMap { $0 as? Rain }.forEach { $0.stop() } // a new tab restarts the rain
        let r = Rain(frame: parent.bounds)
        r.autoresizingMask = [.width, .height]
        parent.addSubview(r)
        r.run()
    }

    private func run() {
        let n = Int(bounds.width / cellW)
        cols = (0..<n).map { _ in
            Col(head: -Double.random(in: 0...30), speed: .random(in: 0.25...0.6), glyphs: (0..<trail).map { _ in pool.randomElement()! })
        }
        start = Date()
        timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func stop() { timer?.invalidate(); removeFromSuperview() }

    private func tick() {
        let t = Date().timeIntervalSince(start)
        if t >= total { stop(); return }
        alphaValue = t > total - fade ? CGFloat((total - t) / fade) : 1
        let rows = bounds.height / cellH
        for i in cols.indices {
            cols[i].head += cols[i].speed
            if cols[i].head - Double(trail) > Double(rows) { cols[i].head = -Double.random(in: 0...6) }
            if Int.random(in: 0..<4) == 0 { cols[i].glyphs[Int.random(in: 0..<trail)] = pool.randomElement()! } // flicker
        }
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        for (x, c) in cols.enumerated() {
            for k in 0..<trail {
                let row = Int(c.head) - k
                if row < 0 { continue }
                let y = bounds.height - CGFloat(row + 1) * cellH
                if y < -cellH { break }
                let a = k == 0 ? 0.95 : 0.65 * pow(1 - Double(k) / Double(trail), 1.6)
                // head is a brighter teal, the tail fades into the dark one
                let color = k == 0 ? NSColor(srgbRed: 0.25, green: 0.78, blue: 0.74, alpha: a)
                                   : NSColor(srgbRed: 0.0, green: 0.42, blue: 0.43, alpha: a)
                String(c.glyphs[k]).draw(at: NSPoint(x: CGFloat(x) * cellW, y: y), withAttributes: [.font: font, .foregroundColor: color])
            }
        }
    }
}
