import AppKit
import Carbon.HIToolbox
import SwiftTerm

// Phase 0 spike: hotkey (⌃`) toggles a panel that grows out of the notch on the screen under the cursor.
// The pty lives in the panel's terminal view, so hiding never kills it (D8).
// The panel never moves or resizes: a layer mask animates from the notch shape to the full shape.

final class NotchPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func performKeyEquivalent(with e: NSEvent) -> Bool { onKey?(e) == true || super.performKeyEquivalent(with: e) }
}

// Radius of the concave flare at the top corners, which joins the shape to the screen's top edge.
let ear: CGFloat = 10

// Notch-style shape (layer coords: y up, maxY is the screen edge). `r` is the outer rect including the
// flares; the body is `r` inset by `ear` on each side, with rounded bottom corners.
func notchPath(_ r: CGRect, radius: CGFloat, closed: Bool = true) -> CGPath {
    let b = r.insetBy(dx: ear, dy: 0)
    let r0 = min(radius, b.height / 2)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: closed ? r.minX : r.maxX, y: r.maxY))
    if closed { p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)) }
    p.addArc(center: CGPoint(x: r.maxX, y: r.maxY - ear), radius: ear, startAngle: .pi / 2, endAngle: .pi, clockwise: false)
    p.addArc(tangent1End: CGPoint(x: b.maxX, y: b.minY), tangent2End: CGPoint(x: b.minX, y: b.minY), radius: r0)
    p.addArc(tangent1End: CGPoint(x: b.minX, y: b.minY), tangent2End: CGPoint(x: b.minX, y: b.maxY), radius: r0)
    p.addLine(to: CGPoint(x: b.minX, y: b.maxY - ear))
    p.addArc(center: CGPoint(x: r.minX, y: r.maxY - ear), radius: ear, startAngle: 0, endAngle: .pi / 2, clockwise: false)
    if closed { p.closeSubpath() }
    return p
}

func animateMask(_ mask: CAShapeLayer, to path: CGPath, duration: CFTimeInterval, done: (() -> Void)? = nil) {
    CATransaction.begin()
    CATransaction.setCompletionBlock(done)
    let a = CABasicAnimation(keyPath: "path")
    a.fromValue = mask.presentation()?.path ?? mask.path
    a.toValue = path
    a.duration = duration
    a.timingFunction = CAMediaTimingFunction(name: .easeOut)
    mask.add(a, forKey: "path")
    mask.path = path
    CATransaction.commit()
}

// View that reports mouse enter/exit/click, even when the app is not active.
final class HoverView: NSView {
    var onEnter: (() -> Void)?, onExit: (() -> Void)?, onClick: (() -> Void)?
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { onEnter?() }
    override func mouseExited(with e: NSEvent) { onExit?() }
    override func mouseDown(with e: NSEvent) { onClick?() }
}

@MainActor final class Controller: NSObject, NSApplicationDelegate {
    var settings = Settings.load()
    let handles = [ResizeHandle(.bottom), ResizeHandle(.left), ResizeHandle(.right), ResizeHandle(.bottomLeft), ResizeHandle(.bottomRight)]
    var startSize = NSSize.zero
    lazy var size = NSSize(width: settings.panelWidth + 2 * ear, height: settings.panelHeight) // body + the two flares
    var panel: NotchPanel!
    var ws: Workspace!
    let tabBar = TabBar()
    let bandStrip = NSTextField(labelWithString: "") // usage strip in the top band, right of the notch
    var bandTimer: Timer?
    let mask = CAShapeLayer()
    var visible = false
    var notch = NSSize(width: 200, height: 32)

    /// One quit path for the menu bar item and ⌘Q: quitting ends every terminal session (D8), so ask if a command is
    /// running. The question is drawn inside the panel (QuitConfirm); this returns .terminateCancel and quits again on "Quit".
    let quitConfirm = QuitConfirm()
    var quitConfirmed = false
    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        let cmds = ws.runningCommands()
        guard !quitConfirmed, !cmds.isEmpty else { return .terminateNow }
        if !visible { show() }
        quitConfirm.show("\(cmds.count == 1 ? "1 command is" : "\(cmds.count) commands are") still running (\(Set(cmds).sorted().joined(separator: ", "))). Quitting ends all terminal sessions.")
        return .terminateCancel
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        Usage.selfCheck()
        Settings.selfCheck()
        Activity.selfCheck()
        Onboarding.selfCheck()
        Onboarding.hooksSelfCheck()
        Totals.selfCheck()
        KiroTotals.selfCheck()
        Totals.refresh(); KiroTotals.refresh()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in Totals.refresh(); KiroTotals.refresh() }
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .popUpMenu // above the menu bar so it covers the notch area
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary] // D16
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false

        let wrap = NSView(frame: NSRect(origin: .zero, size: size))
        wrap.wantsLayer = true
        wrap.layer?.backgroundColor = NSColor.black.cgColor
        mask.frame = wrap.bounds
        mask.fillColor = NSColor.black.cgColor
        wrap.layer?.mask = mask
        panel.contentView = wrap

        // Terminal area sits below the notch band so its first lines are never hidden behind the notch.
        ws = Workspace()
        wrap.addSubview(ws.container)
        wrap.addSubview(tabBar)
        wrap.addSubview(quitConfirm) // above the terminal, below the resize handles
        quitConfirm.onQuit = { [weak self] in self?.quitConfirmed = true; NSApp.terminate(nil) }
        quitConfirm.onCancel = { [weak self] in self?.ws.refocus() }
        bandStrip.lineBreakMode = .byTruncatingTail
        wrap.addSubview(bandStrip)
        // Drag the bottom edge for height, a side edge for width, a bottom corner for both (all grow from the notch's center).
        handles.forEach { h in
            wrap.addSubview(h)
            h.onBegin = { [weak self] in self?.startSize = self?.size ?? .zero }
            h.onDrag = { [weak self, unowned h] dx, dy in
                guard let s = self else { return }
                let n = h.edge.newSize(from: s.startSize, dx: dx, dy: dy)
                s.applySize(width: n.width, height: n.height)
            }
            h.onEnd = { [weak self] in
                guard let self else { return }
                self.settings.panelWidth = self.size.width - 2 * ear
                self.settings.panelHeight = self.size.height
                self.settings.save()
            }
        }
        layoutChrome()
        ws.onChange = { [weak self] in
            guard let self else { return }
            self.tabBar.count = self.ws.tabs.count
            self.tabBar.current = self.ws.current
            self.tabBar.needsDisplay = true
        }
        ws.onChange?()
        tabBar.onSelect = { [weak self] in self?.ws.show($0) }
        tabBar.onNew = { [weak self] in self?.ws.newTab() }
        panel.onKey = { [weak self] e in
            guard let self else { return false }
            if !self.quitConfirm.isHidden { // Return quits, Esc cancels, nothing else reaches the terminal
                if e.keyCode == 36 || e.keyCode == 76 { self.quitConfirm.quit() } else if e.keyCode == 53 { self.quitConfirm.cancel() }
                return true
            }
            return self.ws.handle(e)
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.hide() }
        setupAnchor()
        setupStatusItem()
        setupMainMenu()
        DispatchQueue.main.async { Onboarding.offer() } // first run: offer live Claude data
        registerHotkey()
    }

    // Terminal fills the area below the notch band; the tab strip sits in the band, left of the notch.
    let padX: CGFloat = 10 // black margin left and right of the terminal text; the side resize strips live inside it
    func layoutChrome() {
        let body = size.height - notch.height
        let c: CGFloat = 16 // corner squares; the edge strips run between them
        let frames = [NSRect(x: ear + c, y: 0, width: max(0, size.width - 2 * ear - 2 * c), height: 6),
                      NSRect(x: ear, y: c, width: 6, height: max(0, body - c)),
                      NSRect(x: size.width - ear - 6, y: c, width: 6, height: max(0, body - c)),
                      NSRect(x: ear, y: 0, width: c, height: c),
                      NSRect(x: size.width - ear - c, y: 0, width: c, height: c)]
        for (h, f) in zip(handles, frames) { h.frame = f }
        panel?.invalidateCursorRects(for: panel.contentView!)
        ws.container.frame = NSRect(x: ear + padX, y: 0, width: size.width - 2 * (ear + padX), height: size.height - notch.height)
        quitConfirm.frame = ws.container.frame
        tabBar.frame = NSRect(x: ear + 12, y: size.height - notch.height,
                              width: max(0, (size.width - notch.width) / 2 - ear - 24), height: notch.height)
        let sh = bandStrip.intrinsicContentSize.height
        bandStrip.frame = NSRect(x: (size.width + notch.width) / 2 + 12, y: size.height - notch.height + (notch.height - sh) / 2,
                                 width: max(0, (size.width - notch.width) / 2 - ear - 24), height: sh)
    }

    func refreshBand() { bandStrip.attributedStringValue = Usage.compact(); layoutChrome() }

    /// Resize the open panel in place, keeping it centered under the notch. Limits: sane minimum, fits the screen.
    func applySize(width: CGFloat, height: CGFloat, on screen: NSScreen? = nil) {
        let s = screen ?? panel.screen ?? targetScreen()
        let w = min(max(width, 400 + 2 * ear), s.frame.width - 40), h = min(max(height, 150), s.frame.height - 80)
        guard NSSize(width: w, height: h) != size else { return }
        size = NSSize(width: w, height: h)
        CATransaction.begin()
        CATransaction.setDisableActions(true) // no implicit animation while dragging
        panel.setFrame(NSRect(x: s.frame.midX - w / 2, y: s.frame.maxY - h, width: w, height: h), display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        mask.frame = panel.contentView!.bounds
        mask.path = fullPath
        layoutChrome()
        CATransaction.commit()
    }

    // An app without a main menu has no ⌘C / ⌘V / ⌘A: AppKit routes those through menu key equivalents, and SwiftTerm
    // expects the host to provide them. The menu is never shown (accessory app) but its shortcuts work while the panel is key.
    func setupMainMenu() {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(NSMenuItem(title: "Quit Gravitty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = app
        main.addItem(appItem)
        let edit = NSMenu(title: "Edit")
        // nil target = whoever is first responder, i.e. the focused terminal pane
        edit.addItem(NSMenuItem(title: "Copy", action: Selector(("copy:")), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: Selector(("paste:")), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a"))
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // Menu bar icon: the only way to quit, since the app has no Dock icon and no windows of its own.
    var statusItem: NSStatusItem?
    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let img = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Gravitty") {
            img.isTemplate = true
            item.button?.image = img
        } else {
            item.button?.title = "◆"
        }
        let menu = NSMenu()
        let toggleItem = NSMenuItem(title: "Show / hide terminal (\(settings.hotkey))", action: #selector(toggleFromMenu), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        let setupItem = NSMenuItem(title: "Set up live Claude data…", action: #selector(setupClaudeData), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)
        let hooksItem = NSMenuItem(title: "Set up Claude hooks…", action: #selector(setupHooks), keyEquivalent: "")
        hooksItem.target = self
        menu.addItem(hooksItem)
        let prefsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        let settingsItem = NSMenuItem(title: "Open settings file…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Gravitty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }
    @objc func toggleFromMenu() { toggle() }
    @objc func setupClaudeData() { Onboarding.offer(force: true) }
    @objc func setupHooks() { Onboarding.offerHooks() }
    lazy var settingsWindow = SettingsWindow { [weak self] in self?.apply($0) }
    @objc func showSettings() { settingsWindow.show(settings) }

    /// Live apply. Hover delay and intro rain are read on use; the fake-notch size needs a restart.
    func apply(_ s: Settings) {
        let hotkeyChanged = s.hotkey != settings.hotkey
        settings = s
        if hotkeyChanged { registerHotkey() }
        applySize(width: s.panelWidth + 2 * ear, height: s.panelHeight)
        statusItem?.menu?.items.first?.title = "Show / hide terminal (\(s.hotkey))"
    }

    // `open -t` uses the user's default text editor; a .json file might otherwise open in a browser or an IDE.
    // Settings are read at launch, so edits apply after a restart.
    @objc func openSettings() {
        if !FileManager.default.fileExists(atPath: Settings.url.path) { settings.save() } // never overwrite edits
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", Settings.url.path]
        try? p.run()
    }

    // Real notch size from the screen's safe-area geometry; screens without one get a fake notch (D7).
    // shortcut: fake size hardcoded, make it a setting in Phase 1.
    func notchSize(of s: NSScreen) -> NSSize {
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            return NSSize(width: s.frame.width - l.width - r.width, height: s.safeAreaInsets.top)
        }
        return NSSize(width: settings.fakeNotchWidth, height: settings.fakeNotchHeight)
    }

    // Anchor: a small window over the notch on the primary screen (D6). Fake notch draws black (D7);
    // a real notch needs no drawing. Hovering it for hoverDelay opens the glance (D2, D17).
    var anchor: NSWindow?
    var hoverTimer: Timer?

    func setupAnchor() {
        guard let s = NSScreen.screens.first else { return }
        let n = notchSize(of: s)
        let fake = s.safeAreaInsets.top == 0
        let win = NSSize(width: n.width + (fake ? 2 * ear : 0), height: n.height) // fake notch needs room for the flares
        let w = NSWindow(contentRect: NSRect(x: s.frame.midX - win.width / 2, y: s.frame.maxY - win.height, width: win.width, height: win.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .popUpMenu
        w.backgroundColor = .clear
        w.isOpaque = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        let v = HoverView(frame: NSRect(origin: .zero, size: win))
        v.wantsLayer = true
        if fake {
            let shape = CAShapeLayer()
            shape.path = notchPath(CGRect(origin: .zero, size: win), radius: 12)
            shape.fillColor = NSColor.black.cgColor
            v.layer?.addSublayer(shape)
        }
        v.onEnter = { [weak self] in
            guard let self, !self.visible else { return }
            self.hoverTimer = Timer.scheduledTimer(withTimeInterval: self.settings.hoverDelay, repeats: false) { _ in self.showGlance() }
        }
        v.onExit = { [weak self] in self?.hoverTimer?.invalidate() }
        w.contentView = v
        w.orderFrontRegardless()
        anchor = w
        setupGlance(on: s)
        glow = NotchGlow(screen: s, notch: n)
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateGlow() }
    }

    var glow: NotchGlow?
    var lastWorking: [Agent] = []
    func updateGlow() {
        let w = Activity.working()
        guard w != lastWorking else { return }
        let done = lastWorking.filter { !w.contains($0) && Activity.finishedCleanly($0) }
        lastWorking = w
        glow?.set(w)
        guard !done.isEmpty else { return }
        glow?.flash()
        if settings.finishSound { NSSound(named: settings.soundName)?.play() }
    }

    // Glance: small read-only panel under the notch. Never takes focus; click expands to the full panel (D14).
    var glanceSize = NSSize(width: 600, height: 132) // 580 body + the two flares; the height follows the content
    var glanceScreen: NSScreen?
    let glanceText = NSTextField(labelWithString: "")
    var glanceRefresh: Timer?
    var glance: NSPanel!
    let glanceMask = CAShapeLayer()
    var glanceVisible = false
    var glanceNotch = NSSize(width: 200, height: 32)

    var glanceFull: CGPath { notchPath(CGRect(origin: .zero, size: glanceSize), radius: 16) }
    var glanceNotchShape: CGPath {
        notchPath(CGRect(x: (glanceSize.width - glanceNotch.width) / 2 - ear, y: glanceSize.height - glanceNotch.height,
                         width: glanceNotch.width + 2 * ear, height: glanceNotch.height), radius: 12)
    }

    func setupGlance(on s: NSScreen) {
        glanceScreen = s
        glanceNotch = notchSize(of: s)
        glance = NSPanel(contentRect: NSRect(x: s.frame.midX - glanceSize.width / 2, y: s.frame.maxY - glanceSize.height,
                                             width: glanceSize.width, height: glanceSize.height),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        glance.level = .popUpMenu
        glance.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        glance.isReleasedWhenClosed = false
        glance.backgroundColor = .clear
        glance.isOpaque = false
        glance.hasShadow = false
        let v = HoverView(frame: NSRect(origin: .zero, size: glanceSize))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        glanceMask.frame = v.bounds
        glanceMask.fillColor = NSColor.black.cgColor
        v.layer?.mask = glanceMask
        glanceText.frame = NSRect(x: 16 + ear, y: 10, width: glanceSize.width - 32 - 2 * ear, height: glanceSize.height - glanceNotch.height - 18)
        glanceText.maximumNumberOfLines = 0
        glanceText.alignment = .left
        v.addSubview(glanceText)
        v.onExit = { [weak self] in self?.hideGlance() }
        v.onClick = { [weak self] in self?.hideGlance(); self?.show() }
        glance.contentView = v
    }

    // Re-render the text and resize the panel to fit it (top edge stays on the screen edge).
    func refreshGlance() {
        let text = Usage.render()
        glanceText.attributedStringValue = text
        let lines = text.string.split(separator: "\n", omittingEmptySubsequences: false).count
        let h = glanceNotch.height + 18 + 16 * CGFloat(max(lines, 1))
        guard h != glanceSize.height, let s = glanceScreen else { return }
        glanceSize.height = h
        glance.setFrame(NSRect(x: s.frame.midX - glanceSize.width / 2, y: s.frame.maxY - h, width: glanceSize.width, height: h), display: true)
        glance.contentView?.frame = NSRect(origin: .zero, size: glanceSize)
        glanceMask.frame = glance.contentView!.bounds
        glanceText.frame = NSRect(x: 16 + ear, y: 10, width: glanceSize.width - 32 - 2 * ear, height: h - glanceNotch.height - 18)
        if glanceVisible { glanceMask.removeAllAnimations(); glanceMask.path = glanceFull }
    }

    func showGlance() {
        guard !visible, !glanceVisible else { return }
        glanceVisible = true
        glanceMask.removeAllAnimations()
        glanceMask.path = glanceNotchShape
        refreshGlance()
        glanceMask.path = glanceNotchShape // the size may have changed
        glanceRefresh = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshGlance() }
        glance.orderFrontRegardless()
        animateMask(glanceMask, to: glanceFull, duration: 0.18)
    }

    func hideGlance() {
        guard glanceVisible else { return }
        glanceVisible = false
        glanceRefresh?.invalidate()
        animateMask(glanceMask, to: glanceNotchShape, duration: 0.12) { [weak self] in
            if self?.glanceVisible == false { self?.glance.orderOut(nil) }
        }
    }

    // Screen under the cursor (D6); falls back to main.
    func targetScreen() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main!
    }

    var fullPath: CGPath { notchPath(CGRect(origin: .zero, size: size), radius: 16) }
    var notchShape: CGPath {
        notchPath(CGRect(x: (size.width - notch.width) / 2 - ear, y: size.height - notch.height,
                         width: notch.width + 2 * ear, height: notch.height), radius: 12)
    }

    var rainPlayed = false

    /// A saved size bigger than this screen opens at 80% of the screen; bigger screens get the saved size back.
    func fit(to s: NSScreen) {
        let want = NSSize(width: settings.panelWidth + 2 * ear, height: settings.panelHeight)
        let big = want.width > s.frame.width || want.height > s.frame.height
        applySize(width: big ? s.frame.width * 0.8 : want.width, height: big ? s.frame.height * 0.8 : want.height, on: s)
    }

    func toggle() { visible ? hide() : show() }

    func show() {
        guard !visible else { return }
        visible = true
        hoverTimer?.invalidate()
        hideGlance()
        let s = targetScreen()
        notch = notchSize(of: s)
        fit(to: s)
        refreshBand()
        bandTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshBand() }
        panel.setFrame(NSRect(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height,
                              width: size.width, height: size.height), display: false)
        mask.removeAllAnimations()
        mask.path = notchShape
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        ws.refocus()
        animateMask(mask, to: fullPath, duration: 0.2)
        if settings.introRain, !rainPlayed, let v = ws.container as NSView? { rainPlayed = true; Rain.play(over: v) }
        FileHandle.standardError.write(Data("show: notch=\(s.safeAreaInsets.top > 0) \(notch) screen=\(s.localizedName)\n".utf8))
    }

    func hide() {
        guard visible else { return }
        visible = false
        quitConfirm.isHidden = true
        bandTimer?.invalidate()
        animateMask(mask, to: notchShape, duration: 0.15) { [weak self] in
            if self?.visible == false { self?.panel.orderOut(nil) }
        }
    }

    var hotKeyRef: EventHotKeyRef?
    var hotKeyHandlerInstalled = false

    /// Safe to call again after the hotkey changes: the new key is registered first, so a refused one keeps the old.
    func registerHotkey() {
        if !hotKeyHandlerInstalled {
            hotKeyHandlerInstalled = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, ud in
                Unmanaged<Controller>.fromOpaque(ud!).takeUnretainedValue().toggle()
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4752_5654), id: 1) // 'GRVT'
        var hk = Settings.parseHotkey(settings.hotkey)
        if hk == nil {
            FileHandle.standardError.write(Data("invalid hotkey \"\(settings.hotkey)\", using ctrl+`\n".utf8))
            hk = Settings.parseHotkey("ctrl+`")
        }
        let st = RegisterEventHotKey(hk!.key, hk!.mods, id, GetApplicationEventTarget(), 0, &ref)
        if st != noErr { FileHandle.standardError.write(Data("hotkey registration failed: \(st)\n".utf8)); return }
        if let old = hotKeyRef { UnregisterEventHotKey(old) }
        hotKeyRef = ref
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon
MainActor.assumeIsolated { // top-level code runs on the main thread
    let controller = Controller()
    app.delegate = controller
    app.run()
}
