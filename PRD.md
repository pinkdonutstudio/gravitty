# Gravitty (working name) — PRD draft v0.1

A macOS drop-down terminal that lives in the notch, stays alive while hidden, and shows live agent usage (Claude Code, Kiro CLI).

## Decisions log
| # | Decision | Notes |
|---|----------|-------|
| D1 | Build for the current notched MacBook first-class; Mac mini M2 is a compatibility target | Mini has no notch, uses the fallback pill |
| D2 | **Hover** over the notch = read-only glance (agent status, usage, running sub-agents). **Hotkey** = full interactive terminal | Hover never steals focus or keystrokes |
| D3 | Mac mini runs 2 monitors | Placement rules proposed below, not yet confirmed |
| D4 | Build phases: personal first, then wider | See Phases |
| D5 | Kiro CLI is the second agent after Claude Code | Data surface unverified |
| D6 | Two-monitor placement confirmed: glance anchor on primary screen only; hotkey opens full panel on the cursor's screen; sessions are global | |
| D7 | Screens without a notch get a **fake notch** (black shape at top-center of the primary display) instead of a pill | Same look and code path everywhere; supersedes the pill idea |
| D9 | Claude data source: transcripts + sub-agent files for history/totals; tee of the statusline JSON for live state (exact context %, rate limits, cost). Hooks deferred | Transcript format is undocumented, parser must ignore unknown fields. Verified on Claude Code 2.1.317 |
| D10 | UI is **statusline-style**: compact one/two-line strips, not a dashboard | One strip per session (model, context %, tokens, cost); sub-agents as small extra rows. Totals as a single strip |
| D11 | Kiro provider (v3 engine) reads `~/.kiro/sessions/<workspace>/sess_<id>/`: `session.json` (model, workspace, start time) and `messages.jsonl` (`contextUsage` events for context %, `usage_summary` events for credits per turn). Kiro meters in credits, not tokens. Only sessions whose `.lock` pid is alive and whose log changed in the last 10 min are shown | Replaces my first read of the v2 `sessions/cli/` files, which the v3 TUI does not use. Context window size is not recorded, so no size label. Verified on one session |
| D12 | Kiro v1 uses local per-session data only (D11). No monthly/account usage via HTTP, no reading Kiro's stored login token | Revisit later as an optional extra; see open question 2 |
| D13 | Strip format copies the existing `~/.claude/statusline.sh` look: same fields, gradient bar, colors tied to context use | Reuses design work; Kiro strips use the same layout with credits instead of tokens |
| D14 | Clicking the glance expands it into the full panel | Hover stays read-only; click is the only way to promote it with the mouse |
| D15 | Distribution: personal first, ship later | Matches Phase 4 |
| D16 | Panel opens on the active Space, never pulls you to another desktop. Hotkey opens it over fullscreen apps; hover glance works on regular desktops only | One window collection-behavior setting |
| D17 | Hover delay starts at 200 ms (lowered from 250 after first try), exposed as a setting, tuned by feel | |
| D18 | Live strip implemented: `~/.claude/statusline.sh` now also copies its JSON to `~/.gravitty/live/<session>.json` (backup at `~/.claude/statusline.sh.bak-gravitty`); the glance shows up to 3 recently active sessions in the statusline format, plus one footer with 5h/7d rate limits and total cost | A session counts as live if its file changed in the last 10 min. Sub-agent rows and transcript-based totals are still to do |
| D19 | Settings are a JSON file, `~/.gravitty/settings.json` (hotkey, hover delay, panel size, fake-notch size), read at launch; no settings UI | Created with defaults on first run. Restart to apply. A UI can come in Phase 4 |
| D20 | While an agent works, a bright segment runs around the notch outline like an endless progress bar, always left to right, in the agent's color (Claude orange, Kiro purple). When both work, Claude runs from the left and Kiro from the right and they meet at the bottom center. Claude "working" = the last user/assistant line of its transcript is an open turn. Kiro "working" = the last turn_start/turn_end event in `~/.kiro/sessions/<workspace>/sess_<id>/messages.jsonl` is a turn_start and the session's `.lock` pid is alive (Kiro v3 only; the v2 engine is ignored) | Polled once a second, no hooks. Hooks would be more exact (D9) |
| D21 | Running Claude sub-agents appear as indented rows (`↳ type task │ tokens │ elapsed`) under their session in the glance, up to 3 per session; the glance grows to fit. A sub-agent is running if the last line of its own log (`<session>/subagents/agent-<id>.jsonl`) is an open turn. Tokens = new input + cache writes + output | Kiro: `sub_agent_start` / `sub_agent_complete` events in the parent session's `messages.jsonl` (name, prompt, start time); a `turn_end` clears all. Kiro does not record per-sub-agent tokens or credits, so those rows show only type, task and elapsed time |
| D22 | All-time totals: a `Σ today │ 7d │ all` token line at the bottom of the glance, summed from every Claude Code transcript (sub-agents included), deduplicated by message id + request id, scanned in the background at launch and every 30 s. Tokens = new input + cache writes + output. No dollar cost | No price table (model prices not verified). Kiro is in credits and not included. No on-disk cache yet: launch rescans everything |
| D23 | No dollar costs for Kiro, ever: Kiro stays in credits only | Dollar cost, if added, is for Claude only (needs a verified price table) |
| D24 | Claude plan limits get their own glance line: `Claude limits │ 5h ███░░░░░░░ 5% ↻2h15m │ 7d █░░░░░░░░░ 4% ↻3d4h` (gradient bar, % turning yellow at 70 and red at 90, time until the window resets). Read from the newest statusline copy; a window whose reset time has passed shows `reset`. Replaces dollar cost as the Claude "how much is left" signal | Account-wide, so shown once, not per session. Claude dollar cost is dropped |
| D25 | Distribution build: `scripts/bundle.sh` produces `build/Gravitty.app` (arm64 only, menu-bar-less accessory app via `LSUIElement`, min macOS 14, bundle id `com.pinkdonutstudio.gravitty` (D32)), signed with hardened runtime using `GRAVITTY_SIGN_ID` or ad-hoc | Only an Apple Development certificate exists on this Mac. Notarization needs a Developer ID Application certificate; the Developer ID cert is installed and the script's notarize step (`GRAVITTY_NOTARY_PROFILE`) ran end to end on 2026-11-03: Apple accepted the build, it was stapled, and Gatekeeper reports `Notarized Developer ID`. Intel Macs are not supported |
| D26 | The open panel can be resized by dragging its bottom edge (height), a side edge (width) or a bottom corner (both); it grows evenly from the notch's center and the top edge is not resizable; the size is clamped to the screen and saved to `settings.json` when the drag ends | The glance already resizes itself to its content (D21) |
| D27 | A menu bar icon with "Show / hide terminal" and "Quit Gravitty"; it is the only way to quit the app, which has no Dock icon. Quitting ends all terminal sessions (D8) | No confirmation prompt on quit yet |
| D28 | Onboarding: at launch the app checks whether Claude Code's status line already writes the live copy; if not, it offers (once, with "Don't ask again") to wrap the status-line command in `~/.gravitty/statusline-tee.sh`, which saves the JSON copy and then runs the original command with the same input. Only `statusLine.command` in `~/.claude/settings.json` changes; a backup is saved as `settings.json.bak-gravitty`; an unparseable settings file is never touched. Also in the menu bar menu ("Set up live Claude data…"). Kiro needs no setup | Replaces hand-editing the user's script (D18). Settings.json is rewritten with sorted keys, so its formatting changes. This Mac is detected as already set up |
| D29 | Free and open source under MIT, published under the author's name. Free forever for the core app; no license keys, no payments. Third-party notices (SwiftTerm, MIT) in `THIRD-PARTY-NOTICES.md` | Built first for the author's own use; open source lets others use it and contribute. Closes open question 1 |
| D30 | The name is Gravitty (gravity pulling the terminal down, plus tty). Bundle ID is `com.pinkdonutstudio.gravitty` (D32); settings stay in `~/.gravitty` | Unique, fits the drop-down idea, and a quick web search found no collision. Domain, GitHub name and trademark checks still to do before going public |
| D31 | Intro effect: every time a new tab opens (⌘T or the + button), and the first time the panel opens after each launch, dark-teal falling glyphs (digits, symbols, half-width katakana) rain down over the terminal for about 2.4 s, then fade out. Never takes clicks or keys. Off with `introRain: false` in settings | Gives the first open some personality. Over the terminal area only (not the tab bar). Change if it gets old |
| D32 | Release identity: the repo is `github.com/pinkdonutstudio/gravitty`, the site is `gravitty.pinkdonutstudio.com`, and the bundle id is `com.pinkdonutstudio.gravitty` (the domain reversed). `github.com/Gravitty` is an unused 2015 account, so it is not available | Decided 2026-11-04. Web self-search found no `Gravitty` trademark and no Mac terminal with the name; closest are GRAVITII (live, classes 9/42) and GRAVITY (Gravity, Inc., classes 9/37/42/35), which sounds the same, so the risk is modest for a free open-source tool. USPTO and EUIPO searches by hand are still to do. Changing the bundle id resets the app's saved preferences (only the onboarding "Don't ask again" flag) |
| D33 | Auto-update uses Sparkle 2. The update check is the only network call Gravitty makes: no telemetry, system profiling off, and Sparkle asks the user once before it checks on its own. Feed: `https://github.com/pinkdonutstudio/gravitty/releases/latest/download/appcast.xml`; each release uploads the DMG and a fresh `appcast.xml`. Updates are verified with an EdDSA key; the public key is in `scripts/bundle.sh`, the private key lives in the login keychain | Decided 2026-11-04. XPC services are removed from the embedded framework (the app is not sandboxed). Ad-hoc dev builds get a library-validation exemption; Developer ID builds do not need one. Every release must raise `CFBundleVersion`, which Sparkle compares. Back up the private key (`generate_keys -x`), or no later update can be signed |
| D8 | Sessions live and die with the app, like Yakuake: hiding never kills them, quitting does | No pty-holder daemon, no tmux, no restart persistence. Removes the old open question 1 |

## Goals
1. Long-living drop-down terminal: pty sessions survive hide/show for as long as the app runs (D8).
2. Lives in the notch; pops out from there. Tabs and split panes.
3. Agent statusline strips (D10): tokens, usage, context window, model, running sub-agents (split view), total usage (CodeNotch-style).
4. Agents: Claude Code first, Kiro CLI second.
5. Targets: notched MacBook (primary) and Mac mini M2 (no notch, external display).

## Non-goals (for now)
- Writing our own terminal emulator.
- Being an IDE or a native agent client.
- Linux/Windows.

## Stack (proposed)
- Swift + AppKit (`NSPanel` accessory app, no Dock icon), SwiftUI for the status strips.
- Terminal engine: SwiftTerm behind a protocol (libghostty is a possible later swap).
- Agent data: local file/hook ingestion, no scraping of terminal output.
- Min macOS: 14 (to confirm; M2 Mac mini supports far newer).

## Phases
**Phase 0 — Spike (days).** Borderless panel anchored to the notch, global hotkey, one SwiftTerm session, hide/show without killing the pty.

**Phase 1 — Personal daily driver.** Tabs, split panes, hotkey + hover-to-open, slide animation, per-screen placement, fake-notch fallback (see below), basic settings.

**Phase 2 — Usage strips (Claude Code).** Statusline-style strips (D10): per-session model, context-window fill, tokens, cost, plus one total-usage strip and rate-limit bars. Data per D9. Shown in the hover glance and as a bar in the open panel.

**Phase 3 — Sub-agents and Kiro CLI.** Sub-agent tree in a split view; Kiro CLI adapter behind the same agent-provider interface.

**Phase 4 — Go wider.** Signing, notarization, auto-update, onboarding, docs (license done D29; README done).

## Key design points
- **Notch vs. Mac mini (D7):** the M2 Mac mini has no built-in display, so no notch. On a primary screen without a notch (`safeAreaInsets.top == 0`) draw a fake notch: a black shape at top-center sized like the real one. Same panel, same code path, same look everywhere. Caveat: it covers a few pixels of the menu bar there, so its size should be a setting.
- **Two interaction tiers (D2):** *Glance* (hover): small non-activating panel under the notch showing agent state, tokens, context fill, running sub-agents; closes on mouse exit, never takes focus. *Open* (hotkey): full terminal with tabs/splits and the same status strips; takes focus, closes on hotkey/Esc/click-away.
- **Two monitors (D6):** the glance anchor (real or fake notch) shows only on the screen with the menu bar (primary). The hotkey opens the full panel on the screen containing the mouse cursor, so you never have to reach across monitors. Sessions are global, not per monitor.
- **Long-living (D8):** ptys are owned by the app process. Hide/show only toggles the panel; quitting the app ends all sessions.
- **Agent providers:** one protocol (`sessions`, `usage`, `context`, `model`, `subagents`); Claude and Kiro each implement it.

## Phase success criteria
- **Phase 0:** hotkey toggles a panel that slides from the notch (MacBook) or the fake notch (external display); a shell keeps running while hidden; works on the active Space and over a fullscreen app.
- **Phase 1:** tabs and splits work; hover (250 ms) opens a non-focus-stealing glance and click expands it; the hotkey opens on the cursor's screen with two monitors; you use it as your daily terminal for a week without reaching for another one.
- **Phase 2:** a running Claude Code session shows model, exact context %, tokens, cost and rate limits within 2 s of changing; the total strip matches ccusage within a few percent.
- **Phase 3:** a running Claude sub-agent appears as a row and disappears when done; a Kiro CLI session shows context % and credits.
- **Phase 4:** signed, notarized build installs and runs on a clean Mac (including the M2 mini) with no manual steps.

## Status
- **Phase 0 spike (2026-11-03): done on the MacBook.** Hotkey (⌃`), panel growing out of the notch via an animated mask with concave top flares, text below the notch band, shell survives hide/show, works across Spaces and over fullscreen apps. Unverified: fake notch on a non-notch primary display, Mac mini.
- **Phases 0 to 3: built and hand-checked on the MacBook (2026-11-03).** Hotkey drop-down terminal, notch animation, tabs/splits, settings file, glance with Claude and Kiro strips, sub-agent rows, token totals, plan-limit line, notch running light. Not verified until a Mac mini test: fake notch on a screen without a notch, two-monitor placement, M2 mini. Optional leftovers: Kiro history totals in credits. Next: Phase 4.

- **Phase 4 (started):** app bundle script, signing and notarization done and checked. Menu bar icon with quit (D27), ⌘C/⌘V/⌘A via a hidden main menu, and drag-to-resize for the open panel (D26) added after the last notarized build. Onboarding done (D28). Not done: auto-update, docs (license done D29; README done), usage strips inside the open panel. The name is final.

## Open questions
1. ~~Open source or paid?~~ Decided: free and open source, MIT (D29).
2. Deferred by D12: Kiro account-level usage (monthly credits) via HTTP. Needs the endpoint and auth method confirmed, and a decision on reading Kiro's stored login token.
