# Architecture

MuxShots is one SwiftPM package with a Dock app (with a menu bar item), a command-line client and a native messaging host, plus a Chrome extension written in TypeScript. This document says what lives where and how the pieces talk; the subsystem documents go deeper.

## Targets

| Target | Kind | Holds |
|---|---|---|
| `RookeryCore` | library | Pure models and logic with no system dependencies: windows, groups and the workspace; mixer track settings and equalizer presets; code agent accounts, limits and the Claude Code answer decoder; time zone search. Everything unit-tested lives here. |
| `RookeryPlatform` | library | Everything that talks to macOS: Accessibility and the window server, hotkeys and the event tap, Core Audio process taps and the audio engine, and the code agent usage providers. |
| `RookeryControl` | library | The wire formats shared by the processes: the control socket's requests and messages, and the browser extension's events and commands. |
| `MuxShots` | executable | The app: AppKit controllers and SwiftUI views for the stage, sidebar, mixer, settings and switchers, and the control server. |
| `muxctl` | executable | The command-line client of the control socket. |
| `RookeryChromeHost` | executable (`muxshots-chrome-host`) | Chrome's native messaging host; bundled inside the app. |
| `RookeryCoreTests` | tests | Swift Testing suites for Core and the wire formats. |
| `RookeryPlatformTests` | tests | Swift Testing suites for the Platform wrappers that need no permission, such as process priority. |
| `extensions/chrome` | npm package | The Chrome extension: background service worker, content script, offscreen capture document. |

Warnings are errors and the Swift 6 language mode is on everywhere; see `Package.swift`.

## Processes and how they talk

```
                    ┌──────────── MuxShots.app ────────────┐
  muxctl ──────────►│ ControlServer (unix socket, JSON lines)│
                    │                                        │
  Chrome ──stdio──► muxshots-chrome-host ──socket──► BrowserTabMixer
  (extension)       │                                        │
                    │ WindowTracker ◄─AX/window server─ apps │
                    │ AudioMixer    ◄─process taps──── apps  │
                    │ AgentUsageMonitor ──spawns── claude -p │
                    └────────────────────────────────────────┘
```

- **Control socket**: `~/Library/Application Support/MuxShots/control.sock`, newline-delimited JSON (`ControlConnection`). One request per connection, except `watch` and `browserSession`, which stay open. `muxctl` and the Chrome host are its clients.
- **Browser session**: the extension connects through Chrome's native messaging to `muxshots-chrome-host`, which opens a `browserSession` on the socket and relays messages both ways, re-framing Chrome's 4-byte-length frames as lines. The extension's messages use snake_case keys (`BrowserWire`); everything else uses Swift's default camelCase.
- **Code agents**: limits are read by running the harness itself headless (for Claude Code, `claude -p` with its stream-json control protocol), never by handling the user's credentials.
- **Sidebar videos**: streamed from a Chrome tab over WebRTC on the loopback, played by a `WKWebView` per video; only the connection handshake passes through the browser session.

## The app's main objects

`AppDelegate` creates and wires the long-lived controllers:

- `WorkspaceController` (Accessibility granted): owns the `Workspace` (groups of managed windows), applies actions through `WindowTracker`, runs the stages' layout, the MRU order and the switchers' requests. Persists to `workspace.json`.
- `StageCoordinator` / `StageController` / `StageModel` / `StageView`: the stage windows. Each stage is a borderless panel kept just beneath its front window; its SwiftUI view hosts the sidebar (groups or mixer, sidebar videos, agent limits, world clock, toolbar) and the tab bar.
- `MixerController`: per-app tracks over `AudioMixer`, settings persisted per bundle id; owns `BrowserTabMixer`, the per-tab state from the extension, which owns `BrowserPictures`, the sidebar videos.
- `AgentUsageMonitor`: reads the shown code agent accounts' limits on a schedule and groups accounts signed in to one login.
- `ShortcutController`, `SwitcherController`, `KeyInterceptor`: hotkeys, the group and window switchers, ⌘⇥ while a stage is in front.
- `Preferences`: everything in `UserDefaults` (`io.github.zobinhuang.muxshots`), with change callbacks the controllers subscribe to.
- `ControlServer`: serves `muxctl` and browser sessions.

UI state is `@MainActor`; the window tracker is an actor with a run loop thread per application; audio callbacks run on Core Audio's threads with lock-protected shared buffers.

## Where state lives

| What | Where | Lifetime |
|---|---|---|
| Groups, managed windows, their home frames | `~/Library/Application Support/MuxShots/workspace.json` | Across restarts; windows that no longer exist are dropped |
| Quick notes in the sidebar | `~/Library/Application Support/MuxShots/notes.json` | Until deleted |
| Preferences, hotkeys, world clock cities, agent accounts | `UserDefaults` | Permanent |
| Per-app mixer settings | `UserDefaults` key `mixerTracks` | Permanent, by bundle id |
| Per-tab mixer settings | The extension's `chrome.storage.session` | While the tab and the browser live |
| Agent limits | In memory | Read again on launch |
| Chrome native host registration | `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/io.github.zobinhuang.muxshots.json` | Rewritten by the app at launch when it changed |

## Permissions

| Permission | Needed for | Asked |
|---|---|---|
| Accessibility | Reading and moving windows, the event tap | At first launch |
| System audio recording | Process taps (`NSAudioCaptureUsageDescription`) | The first time an app's sound is taken over |

The app is signed with a fixed local identity (`scripts/create-dev-certificate.sh`) so these grants survive rebuilds; an ad-hoc signature loses them on every build.
