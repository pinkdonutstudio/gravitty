import AppKit

// First-run setup for live Claude Code data. Claude Code pipes its status-line JSON (context %, rate limits, cost) to the
// command in ~/.claude/settings.json; Gravitty needs a copy of it. Instead of editing the user's own status-line script,
// the status-line command is wrapped by ~/.gravitty/statusline-tee.sh, which saves a copy and then runs the original
// command with the same input. Kiro needs no setup (Gravitty reads its session files directly).
enum Onboarding {
    enum Status { case installed, needsSetup, noClaude }
    struct SetupError: Error { var message: String }

    static let wrapperName = "statusline-tee.sh"
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    static var wrapperURL: URL { home.appendingPathComponent(".gravitty/\(wrapperName)") }

    // `$*` is the original status-line command, run through bash so its own quoting and ~ still work.
    // The session id is cut out with sed so jq is not required.
    static let wrapperScript = """
    #!/bin/bash
    # Gravitty: copy Claude Code's status-line JSON for the notch, then run the original status-line command.
    input=$(cat)
    d="$HOME/.gravitty/live"
    sid=$(printf '%s' "$input" | sed -n 's/.*"session_id" *: *"\\([^"]*\\)".*/\\1/p' | head -1)
    if [ -n "$sid" ]; then
      mkdir -p "$d" 2>/dev/null && printf '%s' "$input" > "$d/$sid.tmp" 2>/dev/null && mv "$d/$sid.tmp" "$d/$sid.json" 2>/dev/null
    fi
    [ $# -gt 0 ] && printf '%s' "$input" | bash -c "$*"
    exit 0

    """

    static func json(_ url: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func currentCommand(_ settings: URL) -> String {
        ((json(settings)?["statusLine"] as? [String: Any])?["command"] as? String) ?? ""
    }

    static func status(settings: URL = claudeSettings) -> Status {
        guard FileManager.default.fileExists(atPath: settings.deletingLastPathComponent().path) else { return .noClaude }
        let cmd = currentCommand(settings)
        if cmd.contains(wrapperName) { return .installed }
        // an own script that already writes the copy (how this Mac was set up by hand)
        if let first = cmd.split(separator: " ").first,
           let body = try? String(contentsOfFile: NSString(string: String(first)).expandingTildeInPath, encoding: .utf8),
           body.contains(".gravitty/live") { return .installed }
        return .needsSetup
    }

    /// Wraps the status-line command. Keeps a backup of settings.json and never touches a file it cannot parse.
    static func install(settings: URL = claudeSettings, wrapper: URL = wrapperURL) throws {
        guard status(settings: settings) == .needsSetup else { return }
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if fm.fileExists(atPath: settings.path) {
            guard let r = json(settings) else { throw SetupError(message: "\(settings.path) is not valid JSON, so I left it alone.") }
            root = r
            try? fm.removeItem(at: settings.appendingPathExtension("bak-gravitty"))
            try fm.copyItem(at: settings, to: settings.appendingPathExtension("bak-gravitty"))
        }
        try fm.createDirectory(at: wrapper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try wrapperScript.write(to: wrapper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        var sl = root["statusLine"] as? [String: Any] ?? [:]
        let original = sl["command"] as? String ?? ""
        sl["type"] = "command"
        sl["command"] = "$HOME/.gravitty/\(wrapperName)" + (original.isEmpty ? "" : " " + original)
        root["statusLine"] = sl
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: settings, options: .atomic)
    }

    // MARK: hooks
    // Claude Code hooks tell Gravitty exactly when a turn starts and ends. The script prints nothing (UserPromptSubmit
    // output would otherwise go into the conversation) and only writes a one-word state file per session.

    static let hookName = "hook.sh"
    static var hookURL: URL { home.appendingPathComponent(".gravitty/\(hookName)") }
    static let hookEvents = [("UserPromptSubmit", "working"), ("PreToolUse", "tool"), ("PostToolUse", "working"), ("Stop", "idle"), ("SessionEnd", "idle")]
    static let hookScript = """
    #!/bin/bash
    # Gravitty: record whether a Claude Code session is working ($1 = working | idle). Prints nothing.
    input=$(cat)
    sid=$(printf '%s' "$input" | sed -n 's/.*"session_id" *: *"\\([^"]*\\)".*/\\1/p' | head -1)
    d="$HOME/.gravitty/state"
    if [ -n "$sid" ]; then
      mkdir -p "$d" 2>/dev/null && printf '%s' "$1" > "$d/$sid.tmp" 2>/dev/null && mv "$d/$sid.tmp" "$d/$sid" 2>/dev/null
    fi
    exit 0

    """

    static func hooksInstalled(settings: URL = claudeSettings) -> Bool {
        let hooks = json(settings)?["hooks"] as? [String: Any]
        return hookEvents.allSatisfy { ev, _ in hasOurHook(hooks?[ev]) }
    }

    private static func hasOurHook(_ groups: Any?) -> Bool {
        ((groups as? [[String: Any]]) ?? []).contains { g in
            ((g["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.contains(hookName) == true }
        }
    }

    /// Adds our three hooks next to whatever is already there. Backs up settings.json; never touches a file it cannot parse.
    static func installHooks(settings: URL = claudeSettings, script: URL = hookURL) throws {
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if fm.fileExists(atPath: settings.path) {
            guard let r = json(settings) else { throw SetupError(message: "\(settings.path) is not valid JSON, so I left it alone.") }
            root = r
            let bak = settings.appendingPathExtension("bak-gravitty-hooks")
            try? fm.removeItem(at: bak)
            try fm.copyItem(at: settings, to: bak)
        }
        try fm.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try hookScript.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (ev, state) in hookEvents where !hasOurHook(hooks[ev]) {
            let group: [String: Any] = ["hooks": [["type": "command", "command": "$HOME/.gravitty/\(hookName) \(state)"]]]
            hooks[ev] = ((hooks[ev] as? [Any]) ?? []) + [group]
        }
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: settings, options: .atomic)
    }

    static func offerHooks() {
        let a = NSAlert()
        NSApp.activate(ignoringOtherApps: true)
        if status() == .noClaude {
            a.messageText = "Claude Code was not found"
            a.informativeText = "There is no ~/.claude folder on this Mac."
        } else if hooksInstalled() {
            a.messageText = "Claude Code hooks are already set up"
        } else {
            a.messageText = "Track Claude Code activity with hooks?"
            a.informativeText = """
                Gravitty will add five hooks (UserPromptSubmit, PreToolUse, PostToolUse, Stop, SessionEnd) to ~/.claude/settings.json. They run \
                ~/.gravitty/hook.sh, which only writes a one-word state file to ~/.gravitty/state and prints nothing. \
                Your other hooks are kept, and a backup is saved as settings.json.bak-gravitty-hooks. \
                Sessions that are already open need a restart.
                """
            a.addButton(withTitle: "Set Up")
            a.addButton(withTitle: "Not Now")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            let done = NSAlert()
            do {
                try installHooks()
                done.messageText = "Done"
            } catch {
                done.alertStyle = .warning
                done.messageText = "Setup did not finish"
                done.informativeText = (error as? SetupError)?.message ?? error.localizedDescription
            }
            done.runModal()
            return
        }
        a.runModal()
    }

    static func hooksSelfCheck() {
        #if DEBUG
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("gravitty-hooks-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let settings = tmp.appendingPathComponent("settings.json"), script = tmp.appendingPathComponent(hookName)
        try? Data(#"{"other":1,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"mine.sh"}]}]}}"#.utf8).write(to: settings)
        assert(!hooksInstalled(settings: settings))
        try? installHooks(settings: settings, script: script)
        assert(hooksInstalled(settings: settings) && json(settings)?["other"] as? Int == 1)
        let stop = (json(settings)?["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        assert(stop?.count == 2 && fm.isExecutableFile(atPath: script.path) && fm.fileExists(atPath: settings.path + ".bak-gravitty-hooks"))
        try? installHooks(settings: settings, script: script) // twice adds nothing
        assert(((json(settings)?["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count == 2)
        try? Data("{not json".utf8).write(to: settings)
        assert((try? installHooks(settings: settings, script: script)) == nil && (try? String(contentsOf: settings)) == "{not json")
        #endif
    }

    // MARK: dialogs

    /// At launch (force = false) it asks once, and not again if "Don't ask again" was ticked. From the menu (force = true) it always answers.
    static func offer(force: Bool = false) {
        let a = NSAlert()
        switch status() {
        case .noClaude:
            guard force else { return }
            a.messageText = "Claude Code was not found"
            a.informativeText = "There is no ~/.claude folder on this Mac, so there is nothing to set up. Kiro sessions work without any setup."
        case .installed:
            guard force else { return }
            a.messageText = "Live Claude Code data is already set up"
        case .needsSetup:
            if !force && UserDefaults.standard.bool(forKey: "onboardingDismissed") { return }
            a.messageText = "Show live Claude Code data in Gravitty?"
            a.informativeText = """
                Gravitty shows context use, rate limits and cost from Claude Code's status line. To get them, it will \
                change the status line command in ~/.claude/settings.json so that it also saves a copy of its data to \
                ~/.gravitty. Your current status line keeps working as it does now, and a backup of settings.json is saved \
                next to it as settings.json.bak-gravitty.
                """
            a.addButton(withTitle: "Set Up")
            a.addButton(withTitle: "Not Now")
            a.showsSuppressionButton = true
            a.suppressionButton?.title = "Don't ask again"
            NSApp.activate(ignoringOtherApps: true)
            let r = a.runModal()
            if a.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: "onboardingDismissed") }
            guard r == .alertFirstButtonReturn else { return }
            let done = NSAlert()
            do {
                try install()
                done.messageText = "Done"
                done.informativeText = "Live data appears for Claude Code sessions after their next status line update. Sessions that are already open may need a restart."
            } catch {
                done.alertStyle = .warning
                done.messageText = "Setup did not finish"
                done.informativeText = (error as? SetupError)?.message ?? error.localizedDescription
            }
            done.runModal()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    static func selfCheck() {
        #if DEBUG
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("gravitty-onboarding-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let claude = tmp.appendingPathComponent(".claude"), settings = claude.appendingPathComponent("settings.json")
        let wrapper = tmp.appendingPathComponent(".gravitty/\(wrapperName)")
        try? fm.createDirectory(at: claude, withIntermediateDirectories: true)

        // an existing status line is wrapped, other keys survive, a backup is kept, a second install changes nothing
        try? Data(#"{"other":1,"statusLine":{"type":"command","command":"~/x.sh","padding":0}}"#.utf8).write(to: settings)
        assert(status(settings: settings) == .needsSetup)
        try? install(settings: settings, wrapper: wrapper)
        let sl = json(settings)?["statusLine"] as? [String: Any]
        assert(sl?["command"] as? String == "$HOME/.gravitty/\(wrapperName) ~/x.sh" && sl?["padding"] as? Int == 0)
        assert(json(settings)?["other"] as? Int == 1 && fm.fileExists(atPath: settings.path + ".bak-gravitty"))
        assert(fm.isExecutableFile(atPath: wrapper.path) && status(settings: settings) == .installed)
        let once = currentCommand(settings)
        try? install(settings: settings, wrapper: wrapper)
        assert(currentCommand(settings) == once)

        // no status line configured: the wrapper stands alone
        try? Data("{}".utf8).write(to: settings)
        try? install(settings: settings, wrapper: wrapper)
        assert(currentCommand(settings) == "$HOME/.gravitty/\(wrapperName)")

        // a settings file that does not parse is refused and left untouched
        try? Data("{not json".utf8).write(to: settings)
        assert((try? install(settings: settings, wrapper: wrapper)) == nil && (try? String(contentsOf: settings)) == "{not json")
        #endif
    }
}
