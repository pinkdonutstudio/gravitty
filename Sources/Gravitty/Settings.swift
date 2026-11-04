import Carbon.HIToolbox
import Foundation

// User settings in ~/.gravitty/settings.json, read once at launch (restart to apply).
// The settings window (SettingsWindow.swift) edits the same file and applies changes live.
struct Settings: Codable {
    var hotkey = "ctrl+`"        // modifiers (cmd, ctrl, opt, shift) joined to one key with "+"
    var hoverDelay = 0.2         // seconds (D17)
    var panelWidth = 900.0
    var panelHeight = 420.0
    var fakeNotchWidth = 200.0   // used on screens without a notch (D7)
    var fakeNotchHeight = 32.0
    var finishSound = true       // short system sound when an agent finishes
    var soundName = "Glass"      // any name in /System/Library/Sounds
    var introRain = true         // falling-glyph intro the first time the panel opens after launch (D31)

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? hotkey
        hoverDelay = try c.decodeIfPresent(Double.self, forKey: .hoverDelay) ?? hoverDelay
        panelWidth = try c.decodeIfPresent(Double.self, forKey: .panelWidth) ?? panelWidth
        panelHeight = try c.decodeIfPresent(Double.self, forKey: .panelHeight) ?? panelHeight
        fakeNotchWidth = try c.decodeIfPresent(Double.self, forKey: .fakeNotchWidth) ?? fakeNotchWidth
        fakeNotchHeight = try c.decodeIfPresent(Double.self, forKey: .fakeNotchHeight) ?? fakeNotchHeight
        introRain = try c.decodeIfPresent(Bool.self, forKey: .introRain) ?? introRain
        finishSound = try c.decodeIfPresent(Bool.self, forKey: .finishSound) ?? finishSound
        soundName = try c.decodeIfPresent(String.self, forKey: .soundName) ?? soundName
    }

    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gravitty/settings.json")

    /// Missing file: write the defaults so they can be edited. Broken file: keep it untouched and use defaults.
    static func load() -> Settings {
        guard let data = try? Data(contentsOf: url) else {
            Settings().save()
            return Settings()
        }
        guard var s = try? JSONDecoder().decode(Settings.self, from: data) else {
            FileHandle.standardError.write(Data("settings.json is invalid, using defaults\n".utf8))
            return Settings()
        }
        s.clamp()
        return s
    }

    mutating func clamp() {
        hoverDelay = min(max(hoverDelay, 0), 2)
        panelWidth = min(max(panelWidth, 400), 3000)
        panelHeight = min(max(panelHeight, 150), 2000)
        fakeNotchWidth = min(max(fakeNotchWidth, 100), 500)
        fakeNotchHeight = min(max(fakeNotchHeight, 20), 80)
    }

    /// Writes the file. A hand-edited file that no longer parses is left alone, never overwritten.
    @discardableResult func save() -> Bool {
        if let old = try? Data(contentsOf: Settings.url), (try? JSONDecoder().decode(Settings.self, from: old)) == nil { return false }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? FileManager.default.createDirectory(at: Settings.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? enc.encode(self).write(to: Settings.url)) != nil
    }

    private static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "`": kVK_ANSI_Grave, "space": kVK_Space, "return": kVK_Return, "tab": kVK_Tab, "esc": kVK_Escape,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
        "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash,
    ]

    /// Needs at least one modifier, so a bare key can never be hijacked system-wide.
    static func parseHotkey(_ str: String) -> (key: UInt32, mods: UInt32)? {
        let parts = str.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, let k = keyCodes[parts.last!] else { return nil }
        var mods: UInt32 = 0
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command": mods |= UInt32(cmdKey)
            case "ctrl", "control": mods |= UInt32(controlKey)
            case "opt", "option", "alt": mods |= UInt32(optionKey)
            case "shift": mods |= UInt32(shiftKey)
            default: return nil
            }
        }
        return (UInt32(k), mods)
    }

    static func selfCheck() {
        assert(parseHotkey("ctrl+`")! == (UInt32(kVK_ANSI_Grave), UInt32(controlKey)))
        assert(parseHotkey("Cmd+Shift+Space")! == (UInt32(kVK_Space), UInt32(cmdKey | shiftKey)))
        var c = Settings(); c.hoverDelay = 9; c.panelWidth = 1; c.clamp()
        assert(c.hoverDelay == 2 && c.panelWidth == 400)
        assert(parseHotkey("space") == nil && parseHotkey("hyper+a") == nil && parseHotkey("ctrl+") == nil)
    }
}
