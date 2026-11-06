import AppKit
import SwiftTerm

// Tabs, each holding a tree of split panes (NSSplitView nesting). Panes are SwiftTerm views that own their
// shell, so hiding the panel never kills them (D8). Closing the very last pane starts a fresh shell.
final class Workspace: NSObject, LocalProcessTerminalViewDelegate {
    final class Tab { var root: NSView; init(_ r: NSView) { root = r } }

    let container = NSView()
    private(set) var tabs: [Tab] = []
    private(set) var current = 0
    var onChange: (() -> Void)?

    /// Where the last session ended, so the next launch reopens there (written on quit, shutdown and panel hide).
    static let lastCwdURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gravitty/last-cwd")

    override init() {
        super.init()
        let saved = (try? String(contentsOf: Workspace.lastCwdURL, encoding: .utf8))?.trimmingCharacters(in: .newlines)
        newTab(cwd: saved)
    }

    /// The shell's working directory, read from the kernel, so it works without any shell integration (OSC 7).
    func cwd(of pane: LocalProcessTerminalView) -> String? {
        let pid = pane.process.shellPid
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
    }

    private var activeCwd: String? { (focused ?? leaves(of: tabs[current].root).first).flatMap(cwd(of:)) }

    func saveCwd() {
        guard !tabs.isEmpty, let d = activeCwd else { return }
        try? FileManager.default.createDirectory(at: Workspace.lastCwdURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: Workspace.lastCwdURL, atomically: true, encoding: .utf8)
    }

    func makePane(cwd: String? = nil) -> LocalProcessTerminalView {
        let t = LocalProcessTerminalView(frame: container.bounds)
        t.processDelegate = self
        var isDir: ObjCBool = false // a saved directory may have been deleted since: fall back to the default (home)
        let dir = cwd.flatMap { FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue ? $0 : nil }
        t.startProcess(executable: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", args: ["-l"], currentDirectory: dir)
        return t
    }

    func leaves(of v: NSView) -> [LocalProcessTerminalView] {
        v is LocalProcessTerminalView ? [v as! LocalProcessTerminalView] : v.subviews.flatMap(leaves)
    }
    /// Names of the commands running in the foreground of any pane. An idle shell is its own foreground process group, so a
    /// different group on the pty means a command (build, ssh, an agent) is running. Background helpers, like a prompt's
    /// git daemon, are not in the foreground group and do not count.
    func runningCommands() -> [String] {
        tabs.flatMap { leaves(of: $0.root) }.compactMap { p in
            let shell = p.process.shellPid, fd = p.process.childfd
            guard shell > 0, fd >= 0 else { return nil }
            let fg = tcgetpgrp(fd)
            guard fg > 0, fg != shell else { return nil }
            var name = [CChar](repeating: 0, count: 256)
            return proc_name(fg, &name, UInt32(name.count)) > 0 ? String(cString: name) : "a command"
        }
    }

    var focused: LocalProcessTerminalView? { container.window?.firstResponder as? LocalProcessTerminalView }
    func refocus() { container.window?.makeFirstResponder(focused ?? leaves(of: tabs[current].root).first) }

    // MARK: tabs

    func show(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        tabs.forEach { $0.root.removeFromSuperview() }
        current = i
        let r = tabs[i].root
        r.frame = container.bounds
        r.autoresizingMask = [.width, .height]
        container.addSubview(r)
        container.window?.makeFirstResponder(leaves(of: r).first)
        onChange?()
    }

    func newTab(cwd: String? = nil) {
        let dir = cwd ?? (tabs.isEmpty ? nil : activeCwd)
        tabs.append(Tab(makePane(cwd: dir)))
        show(tabs.count - 1)
        if container.window != nil { Rain.play(over: container) } // no window yet = the first tab built at launch (it rains on first open)
    }

    // MARK: panes

    /// Swap `old` for `new` in whatever holds it (a split view, the container, or a tab's root slot).
    private func replace(_ old: NSView, with new: NSView) {
        new.frame = old.frame
        new.autoresizingMask = [.width, .height]
        old.superview?.replaceSubview(old, with: new)
        tabs.first { $0.root === old }?.root = new
    }

    func split(vertical: Bool) {
        guard let pane = focused else { return }
        let new = makePane(cwd: cwd(of: pane))
        let sv = NSSplitView(frame: pane.frame)
        sv.isVertical = vertical // true = side by side
        sv.dividerStyle = .thin
        replace(pane, with: sv)
        sv.addSubview(pane)
        sv.addSubview(new)
        sv.adjustSubviews()
        container.window?.makeFirstResponder(new)
    }

    func remove(_ pane: LocalProcessTerminalView) {
        guard let ti = tabs.firstIndex(where: { pane.isDescendant(of: $0.root) }) else { return } // already gone
        if let sv = pane.superview as? NSSplitView {
            let sibling = sv.subviews.first { $0 !== pane }!
            pane.removeFromSuperview()
            sibling.removeFromSuperview()
            replace(sv, with: sibling)
            if ti == current { container.window?.makeFirstResponder(leaves(of: sibling).first) }
        } else if tabs.count > 1 {
            tabs.remove(at: ti)
            if ti < current { current -= 1 }
            show(min(ti == current ? ti : current, tabs.count - 1))
        } else {
            let fresh = makePane()
            replace(pane, with: fresh)
            container.window?.makeFirstResponder(fresh)
        }
        pane.process.terminate()
    }

    func cycleFocus(_ step: Int) {
        let l = leaves(of: tabs[current].root)
        guard let f = focused, let i = l.firstIndex(of: f) else { return }
        container.window?.makeFirstResponder(l[(i + step + l.count) % l.count])
    }

    // MARK: shortcuts (⌘T new tab, ⌘W close pane, ⌘D split right, ⌘⇧D split below, ⌘⇧[ ] tabs, ⌘[ ] panes, ⌘1-9)

    func handle(_ e: NSEvent) -> Bool {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard f == .command || f == [.command, .shift], let k = e.charactersIgnoringModifiers?.lowercased() else { return false }
        switch k {
        case "t" where f == .command: newTab()
        case "w" where f == .command: if let p = focused { remove(p) }
        case "d": split(vertical: f == .command)
        case "{": show((current - 1 + tabs.count) % tabs.count)
        case "}": show((current + 1) % tabs.count)
        case "[" where f == .command: cycleFocus(-1)
        case "]" where f == .command: cycleFocus(1)
        case "1"..."9" where f == .command: show(Int(k)! - 1)
        default: return false
        }
        return true
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            if let p = source as? LocalProcessTerminalView { self?.remove(p) }
        }
    }
}

// Tab strip drawn in the band beside the notch: numbered slots plus a "+" slot.
final class TabBar: NSView {
    var count = 1, current = 0
    var onSelect: ((Int) -> Void)?, onNew: (() -> Void)?
    private let cell: CGFloat = 26

    override func draw(_ r: NSRect) {
        for i in 0...count {
            let slot = NSRect(x: CGFloat(i) * cell, y: 0, width: cell, height: bounds.height)
            if i == current {
                Usage.purple.withAlphaComponent(0.4).setFill()
                NSBezierPath(roundedRect: slot.insetBy(dx: 2, dy: 6), xRadius: 5, yRadius: 5).fill()
            }
            let s = NSAttributedString(string: i == count ? "+" : "\(i + 1)",
                                       attributes: [.font: Usage.font, .foregroundColor: i == current ? NSColor.white : Usage.gray])
            let sz = s.size()
            s.draw(at: NSPoint(x: slot.midX - sz.width / 2, y: slot.midY - sz.height / 2))
        }
    }

    override func mouseDown(with e: NSEvent) {
        let i = Int(convert(e.locationInWindow, from: nil).x / cell)
        if i < count { onSelect?(i) } else if i == count { onNew?() }
    }
}
