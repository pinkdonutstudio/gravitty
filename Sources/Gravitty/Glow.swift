import AppKit

// Which stretch of the notch outline (ear to ear, never the top edge) a path covers; each runs from its first point.
enum Outline { case full /* left ear to right ear */, left /* left ear to bottom center */, right /* right ear to bottom center */ }

func outlinePath(_ r: CGRect, radius: CGFloat, _ part: Outline) -> CGPath {
    let b = r.insetBy(dx: ear, dy: 0)
    let r0 = min(radius, b.height / 2)
    let p = CGMutablePath()
    if part == .right {
        p.move(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addArc(center: CGPoint(x: r.maxX, y: r.maxY - ear), radius: ear, startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        p.addArc(tangent1End: CGPoint(x: b.maxX, y: b.minY), tangent2End: CGPoint(x: b.midX, y: b.minY), radius: r0)
        p.addLine(to: CGPoint(x: b.midX, y: b.minY))
        return p
    }
    p.move(to: CGPoint(x: r.minX, y: r.maxY))
    p.addArc(center: CGPoint(x: r.minX, y: r.maxY - ear), radius: ear, startAngle: .pi / 2, endAngle: 0, clockwise: true)
    if part == .left {
        p.addArc(tangent1End: CGPoint(x: b.minX, y: b.minY), tangent2End: CGPoint(x: b.midX, y: b.minY), radius: r0)
        p.addLine(to: CGPoint(x: b.midX, y: b.minY))
    } else {
        p.addArc(tangent1End: CGPoint(x: b.minX, y: b.minY), tangent2End: CGPoint(x: b.maxX, y: b.minY), radius: r0)
        p.addArc(tangent1End: CGPoint(x: b.maxX, y: b.minY), tangent2End: CGPoint(x: b.maxX, y: b.maxY), radius: r0)
        p.addLine(to: CGPoint(x: b.maxX, y: b.maxY - ear))
        p.addArc(center: CGPoint(x: r.maxX, y: r.maxY - ear), radius: ear, startAngle: .pi, endAngle: .pi / 2, clockwise: true)
    }
    return p
}

// While agents work, a bright segment runs around the notch outline like an endless progress bar, always left
// to right. When Claude and Kiro work together, Claude runs from the left and Kiro from the right and the two
// meet at the bottom center. Sits one level below the panels, so it never covers them.
@MainActor final class NotchGlow {
    private let window: NSWindow
    private let host = CALayer()
    private let flashHost = CALayer() // separate from `host`, so a state change does not cut a flash short
    private var running = false
    private let rect: CGRect
    private let lap = 1.8      // seconds per lap
    private let tail = 0.35    // segment length as a fraction of the outline

    init(screen s: NSScreen, notch n: NSSize) {
        let m: CGFloat = 28 // room for the shadow
        let body = NSSize(width: n.width + 2 * ear, height: n.height)
        window = NSWindow(contentRect: NSRect(x: s.frame.midX - body.width / 2 - m, y: s.frame.maxY - body.height - m,
                                              width: body.width + 2 * m, height: body.height + m),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        rect = CGRect(x: m, y: m, width: body.width, height: body.height)
        let v = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        v.wantsLayer = true
        host.frame = v.bounds
        v.layer?.addSublayer(host)
        flashHost.frame = v.bounds
        v.layer?.addSublayer(flashHost)
        window.contentView = v
    }

    private func stroke(_ path: CGPath, _ color: NSColor, alpha: CGFloat) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.frame = host.bounds
        l.path = path
        l.fillColor = nil
        l.strokeColor = color.withAlphaComponent(alpha).cgColor
        l.lineWidth = 4 // half of it falls on the hardware notch and is invisible
        l.lineCap = .round
        return l
    }

    private func run(_ path: CGPath, _ color: NSColor, lap: Double) {
        host.addSublayer(stroke(path, color, alpha: 0.3)) // dim track
        let seg = stroke(path, color, alpha: 1)
        seg.shadowColor = color.cgColor
        seg.shadowOpacity = 1
        seg.shadowRadius = 8
        seg.shadowOffset = .zero
        // end races from 0 to 1, start follows `tail` behind: a moving segment, linear in time
        let end = CAKeyframeAnimation(keyPath: "strokeEnd")
        end.values = [0, 1, 1]
        end.keyTimes = [0, NSNumber(value: 1 / (1 + tail)), 1]
        let start = CAKeyframeAnimation(keyPath: "strokeStart")
        start.values = [0, 0, 1]
        start.keyTimes = [0, NSNumber(value: tail / (1 + tail)), 1]
        let g = CAAnimationGroup()
        g.animations = [end, start]
        g.duration = lap
        g.repeatCount = .infinity
        seg.add(g, forKey: "run")
        host.addSublayer(seg)
    }

    /// A short green pulse around the notch: an agent just finished.
    func flash() {
        let green = NSColor.systemGreen
        let l = stroke(outlinePath(rect, radius: 12, .full), green, alpha: 1)
        l.shadowColor = green.cgColor
        l.shadowOpacity = 1
        l.shadowRadius = 10
        l.shadowOffset = .zero
        l.opacity = 0 // resting value once the pulse is over
        flashHost.addSublayer(l)
        window.orderFrontRegardless()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak l] in
            l?.removeFromSuperlayer()
            if self?.running == false { self?.window.orderOut(nil) }
        }
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [0, 1, 1, 0]
        a.keyTimes = [0, 0.15, 0.5, 1]
        a.duration = 1.6
        l.add(a, forKey: "flash")
        CATransaction.commit()
    }

    /// Empty = hide. Same speed either way: the halves are half the length, so their lap is half as long.
    func set(_ agents: [Agent]) {
        host.sublayers?.forEach { $0.removeFromSuperlayer() }
        running = !agents.isEmpty
        guard running else { if flashHost.sublayers?.isEmpty ?? true { window.orderOut(nil) }; return }
        if agents.count > 1 {
            run(outlinePath(rect, radius: 12, .left), Agent.claude.color, lap: lap / 2)
            run(outlinePath(rect, radius: 12, .right), Agent.kiro.color, lap: lap / 2)
        } else {
            run(outlinePath(rect, radius: 12, .full), agents[0].color, lap: lap)
        }
        window.orderFrontRegardless()
    }
}
