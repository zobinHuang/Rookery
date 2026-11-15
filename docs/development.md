# Development

How to build, test and install Rookery, and how to check each part works without asking the user to click through it.

## Toolchain

- macOS 14.2 or later, Swift 6.2. The Command Line Tools suffice; there is no Xcode project.
- Node.js for the Chrome extension (`npm` installs TypeScript and esbuild locally).
- Once per machine: `scripts/create-dev-certificate.sh` makes the "Rookery Development" signing identity. Without it the app is signed ad hoc and loses its Accessibility and audio grants on every build.

## Building, testing, installing

| Command | Does |
|---|---|
| `swift build` | Builds every Swift target (debug). |
| `make test` | Runs the Swift Testing suites. Plain `swift test` cannot find Swift Testing under the Command Line Tools; the Makefile adds the paths. |
| `make app` | Builds an optimized release and assembles a signed `.build/Rookery.app` (with `rookery-chrome-host` inside). A debug build runs the audio processing and the views several times slower, which shows as heat. |
| `make install` | `make app`, quits the running Rookery, waits for it to exit, copies to `/Applications` and opens it. |
| `make chrome-extension` | `npm ci`, `tsc --noEmit`, bundles into `extensions/chrome/dist`. During work, `cd extensions/chrome && npm run build` is enough. |
| `make icon` | Regenerates `Resources/AppIcon.icns` from `scripts/make-icon.swift`. |
| `cd branding && npm run build:logo` | Renders the pixel crow logo from its model in `branding/src`: `branding/dist/preview.html` with every layout and every agent state animated, and the sidebar's animated logo: `Resources/SidebarLogo.png` and `@2x`, its frames side by side, and `SidebarLogo.json`, how they play. Run it after changing the logo; the app's build only copies them. |

`make install` restarts the user's Rookery: managed windows go back to their places and come back onto the stage, audio taps restart, sidebar videos drop. Mention it when the user is in the middle of something.

## Looking inside the running app

- **`rookeryctl`** (`.build/debug/rookeryctl`, or the installed copy): `list` and `watch` for windows and groups, `manage`/`release`/`focus`/`hide`/`show`/`maximize`/`switch`/`stage` to act, `audio` for the mixer (tracks, levels, tabs, `set`, `mute`, `pip`), `agents` for code agent limits. Add `--json` for the raw messages.
- **Logs**: everything logs to the unified log under subsystem `io.github.zobinhuang.rookery`, with categories `app`, `workspace`, `tracker`, `shortcuts`, `control`, `preferences`, `mixer`, `browser`, `picture`, `chrome`, `agents`:

      /usr/bin/log show --last 5m --info --predicate 'subsystem == "io.github.zobinhuang.rookery" AND category == "agents"'

  Add `--debug` for debug-level messages. Use `/usr/bin/log`: in zsh, `log` is a builtin.
- **Crashes** land in `~/Library/Logs/DiagnosticReports/Rookery-*.ips` (JSON after the first line; the triggered thread's frames say where).
- **CPU**: `top -l 10 -s 4 -stats pid,cpu -pid $(pgrep -x Rookery)` for an average, `sample $(pgrep -x Rookery) 5` for where the time goes. WebKit processes started right after a sidebar video opens belong to Rookery. Heat while Rookery itself is idle usually comes from other applications drawing windows nobody sees; a page's `requestAnimationFrame` rate and `document.visibilityState` in the test Chrome show whether a window counts as visible.

## Verifying UI without the screen

Screen recording is not granted to the terminal, so screenshots of the real app are not possible. Render the SwiftUI views offscreen instead:

1. Concatenate the view sources involved (for the sidebar: `StageModel`, `StageView`, `StageColors`, `MixerView`, `MixerControls`, `SevenSegmentDisplay`, `WorldClock`, `WorldClockView`, `AgentUsagePanel`, `SidebarPicturesView`, …) into one `main.swift` in the scratchpad, with `import` lines stripped and `public` removed from any Core files pulled in.
2. Add stubs for what the views read but cannot run headless: a `MixerController` and `AgentUsageMonitor` with the same properties, filled with sample data; the `StageActions` protocol implemented with no-ops.
3. Host `StageView` in an `NSHostingView` inside a borderless `NSWindow` with the `darkAqua` or `aqua` appearance, run the run loop for half a second, then `bitmapImageRepForCachingDisplay` + `cacheDisplay` and write a PNG.
4. Crop and enlarge with `sips -c <h> <w> --cropOffset <y> <x>` and `sips -z`, then read the PNG.

Check the light and dark themes, and the high-contrast ones when colors change; they are chosen by `StageView`'s environment rather than the window's appearance, so set the stage model's theme as well. Materials (`.regularMaterial`) and `WKWebView` content do not render this way; everything drawn by SwiftUI does.

## Verifying windows

Use windows of your own: open TextEdit documents or Finder windows, find them with `rookeryctl list`, and drive them with `rookeryctl manage`/`switch`/`focus`. Never move or manage the user's windows to test.

## Verifying audio

Make a tone app of your own rather than taking over the user's apps: a tiny AppKit app bundle (with its own bundle id) playing a quiet 440 Hz sine through `AVAudioEngine`. Then:

    rookeryctl audio take <tone-bundle-id>
    rookeryctl audio set <tone-bundle-id> volume=2      # the level rookeryctl reports doubles
    rookeryctl audio release <tone-bundle-id>

Levels come from the meters, which only run while a mixer is on screen; with the sidebar on Groups, `rookeryctl audio` shows level 0.

## Verifying the Chrome extension

Branded Chrome ignores `--load-extension`, and the user's Chrome must not be used for tests. Use Chrome for Testing with a throwaway profile:

    npx @puppeteer/browsers install chrome@stable --path <scratchpad>/cft
    mkdir -p <profile>/NativeMessagingHosts
    cp ~/Library/Application\ Support/Google/Chrome/NativeMessagingHosts/io.github.zobinhuang.rookery.json <profile>/NativeMessagingHosts/
    "<cft>/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" \
        --user-data-dir=<profile> --load-extension=extensions/chrome/dist \
        --autoplay-policy=no-user-gesture-required --mute-audio \
        --no-first-run --no-default-browser-check --remote-debugging-port=9333 http://localhost:8765/

- Serve test pages from the scratchpad with `python3 -m http.server 8765`: a page with a quiet `<audio>` for the mixer, a page with a real `<video>` file that has an audio track for sidebar videos (a muted, video-only element is paused by Chrome in background tabs).
- Drive and inspect it over the DevTools protocol: `curl localhost:9333/json` lists targets (the extension's service worker shows by its id), and a small Node script with the built-in `WebSocket` can `Runtime.evaluate` in the page or the service worker, e.g. to read `chrome.tabs.query` or wrap `chrome.tabs.update` to see what the extension does.
- `rookeryctl audio` lists the tabs with `tab:<session>.<tab>` targets to `take`, `set`, `mute` and `pip`.
- Start each test from a fresh profile: Chrome keeps running the old service worker after the dist changes, and `chrome.runtime.reload()` does not bring back a command-line-loaded extension.
- Close the test Chrome and the HTTP server as soon as the test is done.

## Verifying code agent usage

`rookeryctl agents` shows each account's limits, or the error. To see the raw answers, run the harness the way the provider does (see [agent-usage.md](agent-usage.md)) from a scratchpad directory and print only the fields you need; never print credentials.

## Committing

Follow `humanize/git-conventions.md`: one-line Conventional Commits, one concern each, every commit building and passing tests, no code agent attribution. Stage selectively (`git add -p` takes scripted answers such as `printf 'y\nn\n' | git add -p <file>`), and check doubtful intermediate commits with `git worktree add --detach <dir> <commit>` and `swift build` there.
