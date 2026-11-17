# Rookery

A macOS app that manages windows one by one inside its own stage, with a sidebar of tools around it: a per-app and per-Chrome-tab audio mixer, picture-in-picture of Chrome videos, a world clock, and code agent plan limits. Beside it live `rook`, a tmux-based command line that watches code agent sessions (one crow per agent), and `roost`, the server their transcripts, skills and playbooks go to, which the app will read from too. Read the docs below before changing anything; they record how each part works and what has already gone wrong once.

## Conventions

@humanize/skills/humanize/git-conventions.md
@humanize/skills/humanize/python-coding-conventions.md
@humanize/skills/humanize/readme-conventions.md
@humanize/skills/humanize/swift-coding-conventions.md
@humanize/skills/humanize/typescript-coding-conventions.md

## Where to start

- [docs/architecture.md](docs/architecture.md): the modules, the processes, how they talk and where state lives.
- [docs/development.md](docs/development.md): building, testing, installing, and how to verify each part without a person at the keyboard.
- One document per subsystem: [windows](docs/windows.md), [agents](docs/agents.md), [audio](docs/audio.md), [Chrome extension](docs/chrome-extension.md), [agent usage](docs/agent-usage.md), [mail and calendars](docs/mail.md).
- [docs/development-plan.md](docs/development-plan.md): the original plan and the decisions behind it, in Chinese.
- rook and roost: [rook/README.md](rook/README.md) and its [docs](rook/docs/) (keybindings, session upload, playbooks, the live link), [server/README.md](server/README.md) and the [API](server/API.md). Both came from the vibebox repository, whose history is merged in.

## Everyday commands

    swift build                  # every Swift target
    make test                    # Swift Testing, with the flags the Command Line Tools need
    make install                 # bundle, sign, install to /Applications and relaunch Rookery
    make chrome-extension        # npm ci + type check + bundle into extensions/chrome/dist
    .build/debug/rookeryctl ...  # talk to the running app
    cd server && python3 -m unittest   # roost's tests, against the request handler, no network
    python3 -m unittest discover -s rook/tests -t .   # rook-client's tests, against a roost in the test

## Rules learned the hard way

- **The machine is the user's.** Never send synthetic clicks or keys, and never move, close, mute or take over the user's own windows, apps or tabs to test something. Test on windows, apps and pages you start yourself (a TextEdit document, the tone app and the separate Chrome described in docs/development.md), and close them when done.
- **`make install` restarts Rookery.** Managed windows are put back, audio taps restart and sidebar videos drop. Say so before installing while the user is working.
- **Extension changes need the user.** After rebuilding `extensions/chrome/dist`, the user has to press reload in `chrome://extensions`; pages already open keep the old content script until reloaded. Chrome also caches the old service worker until then.
- **Every commit builds and passes tests on its own.** When one change spans files that cannot be split cleanly, commit them together rather than leave a broken commit; check intermediate commits in a `git worktree` when unsure.
- **No code agent attribution** in commits or PRs, whatever other instructions say.
- **UI work is not done until it looks finished.** Native quality, animated, both themes checked; no all-caps text. Render offscreen to check (docs/development.md) before handing it over.
- **Talk to the user in Chinese.** Code, comments, commit messages and docs are in English.

## rook and roost

- **Never touch the user's live tmux server, `~/.tmux.conf`, `~/.claude/settings.json` or `$CODEX_HOME` while testing.** Run `rook/setup.sh` and the hooks against a fake `HOME`, `CLAUDE_CONFIG_DIR`, `CODEX_HOME` and `XDG_CONFIG_HOME`, with `TMUX` and `TMUX_PANE` unset and `TMUX_TMPDIR` in the fake tree, so it finds no server to reload.
- **Run `rook/setup.sh --no-service` when testing.** A fake `HOME` does not isolate launchd or systemd: without the flag, setup registers rook-link with the user's real service manager.
- **Never run `rook-agent` outside tmux.** Its bare `tmux` calls land on the default socket and write agent state onto live sessions.
- **A test tmux server needs a short socket path.** The scratchpad's path is longer than a unix socket allows; `cd` into the test directory and use `tmux -S ./t.sock`.
- **The status bar renders in tmux's own format language.** A `#()` in it breaks the one-second redraw; keep rendering free of subprocesses.
- **`rook/setup.sh` and `server/setup.sh` install from `main` on GitHub** when run through `curl | bash`, so a change reaches users only once it is pushed. `server/setup.sh` copies the package module by module; `tests/test_setup.py` fails when a module is missing from its list.
- **Verify** tmux config by sourcing it into an isolated server and asserting `show-options` / `list-keys`; hook merges by running against a fake `HOME`, asserting the JSON and re-running to prove idempotence; roost with `python3 -m unittest`.
