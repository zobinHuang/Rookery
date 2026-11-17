# Architecture

Rookery is one SwiftPM package with a Dock app (with a menu bar item), a command-line client and a native messaging host, plus a Chrome extension written in TypeScript. This document says what lives where and how the pieces talk; the subsystem documents go deeper.

## Targets

| Target | Kind | Holds |
|---|---|---|
| `RookeryCore` | library | Pure models and logic with no system dependencies: windows, groups and the workspace; mixer track settings and equalizer presets; code agent accounts, limits and the Claude Code answer decoder; time zone search. Everything unit-tested lives here. |
| `RookeryPlatform` | library | Everything that talks to macOS: Accessibility and the window server, hotkeys and the event tap, Core Audio process taps and the audio engine, and the code agent usage providers. |
| `RookeryControl` | library | The wire formats shared by the processes: the control socket's requests and messages, and the browser extension's events and commands. |
| `Rookery` | executable | The app: AppKit controllers and SwiftUI views for the stage, sidebar, mixer, settings and switchers, and the control server. |
| `rookeryctl` | executable | The command-line client of the control socket. |
| `RookeryChromeHost` | executable (`rookery-chrome-host`) | Chrome's native messaging host; bundled inside the app. |
| `RookeryCoreTests` | tests | Swift Testing suites for Core and the wire formats. |
| `RookeryPlatformTests` | tests | Swift Testing suites for the Platform wrappers that need no permission, such as process priority. |
| `extensions/chrome` | npm package | The Chrome extension: background service worker, content script, offscreen capture document. |
| `rook/` | shell | The command line around code agents in tmux: `rook` sessions, `rook-agent` (each pane's agent state and the status bar), `rook-hooks` (merges the hooks into Claude Code and codex), `rook-session` (uploads transcripts), `rook-playbook` (installs a playbook's skills), `rook-client` (reports agent events to roost, backs `rook resource` and `rook message`), `rook-link` (the live link to roost, a user service that types prompts and messages into agents' panes; see `rook/docs/link.md`), and `setup.sh`. See `rook/README.md`. |
| `server/roost` | Python package | The server rook reports to: session transcripts, and the resources (agents, skills, playbooks, memories), their relations and the event log, in SQLite, over HTTP with a bearer token and a live event stream. See `docs/resources.md`. Standard library only. See `server/README.md` and `server/API.md`. |
| `branding/` | npm package | The pixel crow logo, rendered from a 3D model into the sidebar's frames and the preview page. |

Warnings are errors and the Swift 6 language mode is on everywhere; see `Package.swift`.

## Processes and how they talk

```
                    ┌──────────── Rookery.app ────────────┐
  rookeryctl ──────────►│ ControlServer (unix socket, JSON lines)│
                    │                                        │
  Chrome ──stdio──► rookery-chrome-host ──socket──► BrowserTabMixer
  (extension)       │                                        │
                    │ WindowTracker ◄─AX/window server─ apps │
                    │ AudioMixer    ◄─process taps──── apps  │
                    │ AgentUsageMonitor ──spawns── claude -p │
                    └────────────────────────────────────────┘
```

- **Control socket**: `~/Library/Application Support/Rookery/control.sock`, newline-delimited JSON (`ControlConnection`). One request per connection, except `watch` and `browserSession`, which stay open. `rookeryctl` and the Chrome host are its clients.
- **Browser session**: the extension connects through Chrome's native messaging to `rookery-chrome-host`, which opens a `browserSession` on the socket and relays messages both ways, re-framing Chrome's 4-byte-length frames as lines. The extension's messages use snake_case keys (`BrowserWire`); everything else uses Swift's default camelCase.
- **Code agents**: limits are read by running the harness itself headless (for Claude Code, `claude -p` with its stream-json control protocol), never by handling the user's credentials.
- **Sidebar videos**: streamed from a Chrome tab over WebRTC on the loopback, played by a `WKWebView` per video; only the connection handshake passes through the browser session.

## The app's main objects

`AppDelegate` creates and wires the long-lived controllers:

- `WorkspaceController` (Accessibility granted): owns the `Workspace` (groups of managed windows), applies actions through `WindowTracker`, runs the stages' layout, the MRU order and the switchers' requests. Persists to `workspace.json`.
- `StageCoordinator` / `StageController` / `StageModel` / `StageView`: the stage windows. Each stage is a borderless panel kept just beneath its front window; its SwiftUI view hosts the sidebar (windows, agents or mixer, sidebar videos, agent limits, toolbar), the tab bar, and the footbar along the bottom with the world clock.
- `MixerController`: per-app tracks over `AudioMixer`, settings persisted per bundle id; owns `BrowserTabMixer`, the per-tab state from the extension, which owns `BrowserPictures`, the sidebar videos.
- `FleetModel`: the agents roost knows of, kept current over its live link, and the user's local groups of them; backs the sidebar's Agents mode and each agent's page. See `docs/agents.md`.
- `AgentUsageMonitor`: reads the shown code agent accounts' limits on a schedule and groups accounts signed in to one login.
- `ShortcutController`, `SwitcherController`, `KeyInterceptor`: hotkeys, the group and window switchers, ⌘⇥ while a stage is in front.
- `Preferences`: everything in `UserDefaults` (`io.github.zobinhuang.rookery`), with change callbacks the controllers subscribe to.
- `ControlServer`: serves `rookeryctl` and browser sessions.

Every icon in the app is a `RookeryIcon`, in the logo's colors: badges are a dark body lit from the top left inside a yellow outline, glyphs are one color and take the text's. The crow's head and the crow are its pixel art, drawn by `branding/src/icons.ts` into `Resources/Icons` like the logo and the crows; every other icon is drawn at the screen's full resolution from a system symbol. Add an icon as a case with its symbol.

UI state is `@MainActor`; the window tracker is an actor with a run loop thread per application; audio callbacks run on Core Audio's threads with lock-protected shared buffers.

## Where state lives

| What | Where | Lifetime |
|---|---|---|
| Groups, managed windows, their home frames | `~/Library/Application Support/Rookery/workspace.json` | Across restarts; windows that no longer exist are dropped |
| Preferences, hotkeys, world clock cities, agent accounts | `UserDefaults` | Permanent |
| Per-app mixer settings | `UserDefaults` key `mixerTracks` | Permanent, by bundle id |
| Per-tab mixer settings | The extension's `chrome.storage.session` | While the tab and the browser live |
| Agent limits | In memory | Read again on launch |
| roost's address; its token | `UserDefaults` key `roostAddress`; `~/Library/Application Support/Rookery/roost-token`, mode 0600, moved once from the login keychain (service `io.github.zobinhuang.rookery`, account `roost-token`), which asked again after every rebuild of an app signed with a self-made certificate | Permanent |
| Teams of agents | roost's `team` resources; their layout in `~/Library/Application Support/Rookery/agent-teams.json` | Permanent |
| Hosts and workdirs | `~/Library/Application Support/Rookery/hosts.json`; hosts read from `~/.ssh/config` | Permanent |
| Chrome native host registration | `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/io.github.zobinhuang.rookery.json` | Rewritten by the app at launch when it changed |

The app was called MuxShots until it was renamed Rookery, with a new bundle identifier. On its first launch, before anything reads them, `MuxShotsMigration` copies the settings over from the old identifier's defaults domain and moves `~/Library/Application Support/MuxShots` to `Rookery`; neither happens when Rookery already has its own, and the old domain is left in place. `ChromeNativeHost` removes the old host registration (`io.github.zobinhuang.muxshots.json`), and `make install` quits and removes an installed `MuxShots.app`. What a new identifier cannot keep, the user grants again: Accessibility, audio capture, and opening at login. The extension's id is fixed by its key, so the native host still accepts it, but the extension must be rebuilt and reloaded to connect to the new host name. Builds are signed with `Rookery Development`, or with `MuxShots Development` while that is the only identity made.

## Permissions

| Permission | Needed for | Asked |
|---|---|---|
| Accessibility | Reading and moving windows, the event tap | At first launch |
| System audio recording | Process taps (`NSAudioCaptureUsageDescription`) | The first time an app's sound is taken over |

The app is signed with a fixed local identity (`scripts/create-dev-certificate.sh`) so these grants survive rebuilds; an ad-hoc signature loses them on every build.
