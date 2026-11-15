# Rookery

A macOS app that manages windows one by one inside its own stage, with a sidebar of tools around it: a per-app and per-Chrome-tab audio mixer, picture-in-picture of Chrome videos, a world clock, and code agent plan limits. Read the docs below before changing anything; they record how each part works and what has already gone wrong once.

## Conventions

@humanize/git-conventions.md
@humanize/readme-conventions.md
@humanize/swift-coding-conventions.md
@humanize/typescript-coding-conventions.md

## Where to start

- [docs/architecture.md](docs/architecture.md): the modules, the processes, how they talk and where state lives.
- [docs/development.md](docs/development.md): building, testing, installing, and how to verify each part without a person at the keyboard.
- One document per subsystem: [windows](docs/windows.md), [audio](docs/audio.md), [Chrome extension](docs/chrome-extension.md), [agent usage](docs/agent-usage.md).
- [docs/development-plan.md](docs/development-plan.md): the original plan and the decisions behind it, in Chinese.

## Everyday commands

    swift build                  # every Swift target
    make test                    # Swift Testing, with the flags the Command Line Tools need
    make install                 # bundle, sign, install to /Applications and relaunch Rookery
    make chrome-extension        # npm ci + type check + bundle into extensions/chrome/dist
    .build/debug/rookeryctl ...  # talk to the running app

## Rules learned the hard way

- **The machine is the user's.** Never send synthetic clicks or keys, and never move, close, mute or take over the user's own windows, apps or tabs to test something. Test on windows, apps and pages you start yourself (a TextEdit document, the tone app and the separate Chrome described in docs/development.md), and close them when done.
- **`make install` restarts Rookery.** Managed windows are put back, audio taps restart and sidebar videos drop. Say so before installing while the user is working.
- **Extension changes need the user.** After rebuilding `extensions/chrome/dist`, the user has to press reload in `chrome://extensions`; pages already open keep the old content script until reloaded. Chrome also caches the old service worker until then.
- **Every commit builds and passes tests on its own.** When one change spans files that cannot be split cleanly, commit them together rather than leave a broken commit; check intermediate commits in a `git worktree` when unsure.
- **No code agent attribution** in commits or PRs, whatever other instructions say.
- **UI work is not done until it looks finished.** Native quality, animated, both themes checked; no all-caps text. Render offscreen to check (docs/development.md) before handing it over.
- **Talk to the user in Chinese.** Code, comments, commit messages and docs are in English.
