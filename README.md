# Gravitty

A drop-down terminal for macOS that lives in the notch, in the spirit of Yakuake. Press a hotkey and the terminal grows out of the notch. Press it again and it hides, but your shells keep running. It also shows what your Claude Code and Kiro CLI sessions are doing.

- **Long-living sessions.** Hiding the panel never closes a shell. Quitting the app does.
- **Notch native.** It grows out of the real notch. On screens without one (an external monitor, a Mac mini) it draws a fake notch so it looks the same.
- **Tabs and splits** inside the panel.
- **Hover glance.** Hover the notch for a moment to see a statusline-style summary of your agents, without opening the terminal.
- **Running light.** A light travels around the notch while an agent works: orange for Claude, purple for Kiro. If both are working, the two lights run in opposite directions and meet in the middle.

## What the glance shows

**Claude Code** (per session): model, context-window fill, tokens, running sub-agents, plan limits (5-hour and 7-day usage with reset countdowns), and token totals for today, the last 7 days and all time.

**Kiro CLI** (v3): credits used, context fill, and running sub-agents. No dollar costs are shown.

## Requirements

- macOS 14 or later, Apple silicon
- Swift toolchain to build from source (Xcode or the command-line tools)

## Build and run

```sh
scripts/bundle.sh          # builds build/Gravitty.app, ad-hoc signed
open build/Gravitty.app
```

For a signed and notarized build, set `GRAVITTY_SIGN_ID` to a Developer ID identity and `GRAVITTY_NOTARY_PROFILE` to a `notarytool` keychain profile before running the script. Details are in the header of `scripts/bundle.sh`.

## Usage

| Action | Shortcut |
| --- | --- |
| Show or hide the terminal | ⌃` (configurable) |
| New tab | ⌘T |
| Close the focused pane | ⌘W |
| Split vertically / horizontally | ⌘D / ⌘⇧D |
| Move focus between panes | ⌘[ / ⌘] |
| Previous / next tab | ⌘⇧[ / ⌘⇧] |
| Go to tab 1 to 9 | ⌘1 to ⌘9 |

Drag the bottom edge, the side edges or the bottom corners to resize the open panel. The menu bar icon lets you show or hide the terminal, open the settings file, set up Claude data, and quit.

## Settings

`~/.gravitty/settings.json`, created on first run:

```json
{
  "hotkey": "ctrl+`",
  "hoverDelay": 0.2,
  "panelWidth": 900,
  "panelHeight": 420,
  "fakeNotchWidth": 200,
  "fakeNotchHeight": 32,
  "introRain": true
}
```

The hotkey is modifiers (`cmd`, `ctrl`, `opt`, `shift`) joined to one key with `+`. `introRain` turns the falling-glyph intro (every new tab, and the first open after launch) on or off. Restart the app after editing. Values out of range are clamped. A file that doesn't parse is never overwritten.

## Claude Code setup

Claude Code only hands its live data (context fill, plan limits) to its status-line command. On first launch Gravitty offers to wrap that command in a small script, `~/.gravitty/statusline-tee.sh`, which saves a copy of the data and then runs your original command unchanged. You can also run it from the menu bar icon ("Set up live Claude data…").

What it changes: only `statusLine.command` in `~/.claude/settings.json`. A backup is saved next to it as `settings.json.bak-gravitty`. Be aware that the file is rewritten with sorted keys, so its formatting changes. A settings file that isn't valid JSON is left untouched.

Kiro needs no setup.

## Updates

Gravitty checks GitHub for new releases with [Sparkle](https://sparkle-project.org). It asks once before it starts checking on its own, and you can turn that off in Settings or check by hand from the menu bar icon ("Check for Updates…"). Updates are signed, and the app refuses one that does not match its built-in public key. A build made with `swift build` instead of `scripts/bundle.sh` has no update check.

## What Gravitty reads

Everything is local and read-only, and there are no accounts. The only network call is the update check (see Updates below); nothing else leaves your Mac, and there is no telemetry.

- `~/.claude/projects/**/*.jsonl`: Claude transcripts and sub-agent logs, for tokens and totals
- `~/.gravitty/live/*.json`: the copies saved by the wrapper above
- `~/.kiro/sessions/**`: Kiro session messages and metadata. Gravitty never reads Kiro's login token.

The one thing it writes outside `~/.gravitty` is the Claude setup above, and only if you accept it.

## Known limits

- Tested on a notched MacBook. The fake notch on a screen without a notch, and two-monitor placement, are built but not yet checked on a Mac mini.
- Kiro v3 only.

## License

MIT, see [LICENSE](LICENSE). Third-party notices are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). The terminal is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
