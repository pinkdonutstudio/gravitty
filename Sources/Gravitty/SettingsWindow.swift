import AppKit

// Settings window: the same fields as ~/.gravitty/settings.json. Save writes the file and applies live.
@MainActor final class SettingsWindow {
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let hotkey = NSTextField(), hover = NSTextField(), width = NSTextField(), height = NSTextField()
    private let fakeW = NSTextField(), fakeH = NSTextField()
    private let rain = NSButton(checkboxWithTitle: "Falling-glyph intro", target: nil, action: nil)
    private let soundOn = NSButton(checkboxWithTitle: "Sound when an agent finishes", target: nil, action: nil)
    private let sound = NSPopUpButton()
    private let msg = NSTextField(labelWithString: "")
    private let onSave: (Settings) -> Void
    var updater: Updater?
    private let autoUpdate = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)

    init(onSave: @escaping (Settings) -> Void) {
        self.onSave = onSave
        autoUpdate.target = self; autoUpdate.action = #selector(toggleAutoUpdate)
        window.title = "Gravitty Settings"
        window.isReleasedWhenClosed = false
        func row(_ t: String, _ f: NSView) -> [NSView] { f.widthAnchor.constraint(equalToConstant: 160).isActive = true; return [NSTextField(labelWithString: t), f] }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []).map { ($0 as NSString).deletingPathExtension }.sorted()
        sound.addItems(withTitles: names)
        sound.target = self; sound.action = #selector(previewSound)
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        msg.textColor = .systemRed
        let grid = NSGridView(views: [
            row("Hotkey", hotkey), row("Hover delay (s)", hover), row("Panel width", width), row("Panel height", height),
            row("Fake notch width*", fakeW), row("Fake notch height*", fakeH), [NSView(), rain], [NSView(), soundOn], [NSView(), autoUpdate], row("Sound", sound),
            [NSView(), save], [NSView(), msg],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        let note = NSTextField(labelWithString: "* applies after restart")
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        let v = NSView()
        v.addSubview(grid); v.addSubview(note)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: v.topAnchor, constant: 20), grid.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            note.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 8), note.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            v.widthAnchor.constraint(equalToConstant: 380), v.bottomAnchor.constraint(equalTo: note.bottomAnchor, constant: 16),
        ])
        window.contentView = v
    }

    func show(_ s: Settings) {
        hotkey.stringValue = s.hotkey
        hover.stringValue = "\(s.hoverDelay)"
        width.stringValue = "\(Int(s.panelWidth))"; height.stringValue = "\(Int(s.panelHeight))"
        fakeW.stringValue = "\(Int(s.fakeNotchWidth))"; fakeH.stringValue = "\(Int(s.fakeNotchHeight))"
        rain.state = s.introRain ? .on : .off
        soundOn.state = s.finishSound ? .on : .off
        sound.selectItem(withTitle: s.soundName)
        autoUpdate.isHidden = updater?.available != true
        autoUpdate.state = updater?.automatic == true ? .on : .off
        msg.stringValue = ""
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // Sparkle stores this itself and applies it at once, so it does not wait for Save.
    @objc private func toggleAutoUpdate() { updater?.automatic = autoUpdate.state == .on }

    @objc private func previewSound() { NSSound(named: sound.titleOfSelectedItem ?? "")?.play() }

    @objc private func save() {
        let key = hotkey.stringValue.trimmingCharacters(in: .whitespaces)
        guard Settings.parseHotkey(key) != nil else { msg.stringValue = "Hotkey needs a modifier and a key, like ctrl+`"; return }
        let n = [hover, width, height, fakeW, fakeH].map { Double($0.stringValue.trimmingCharacters(in: .whitespaces)) }
        guard !n.contains(where: { $0 == nil }) else { msg.stringValue = "Sizes and delay must be numbers"; return }
        var s = Settings()
        s.hotkey = key
        (s.hoverDelay, s.panelWidth, s.panelHeight, s.fakeNotchWidth, s.fakeNotchHeight) = (n[0]!, n[1]!, n[2]!, n[3]!, n[4]!)
        s.introRain = rain.state == .on
        s.finishSound = soundOn.state == .on
        s.soundName = sound.titleOfSelectedItem ?? s.soundName
        s.clamp()
        guard s.save() else { msg.stringValue = "settings.json has a syntax error. Fix or delete it first."; return }
        onSave(s)
        window.close()
    }
}
