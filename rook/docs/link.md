# The live link

Once `rook connect` names a server, `rook-link` holds a WebSocket open to it. Setup installs it as a user service (a launchd agent on macOS, a systemd user unit on Linux) that idles until the machine is connected, and follows `rook connect` and `rook disconnect` on its own. Over the link it sends the agents' events, and it takes the prompts and messages meant for this machine's agents.

```bash
rook link                    # is the link up, and to where
rook link prompts off        # stop prompts reaching agents here; `on` again to allow them
rook message <agent> <text>  # send another agent a message, as the agent in this pane
```

## How text reaches an agent

An agent is a session, and rook notes the tmux pane each session starts in. A delivery for an agent:

| The agent is | What rook-link does |
|---|---|
| idle, done, stopped on an error or a usage limit | pastes the text into its pane and presses Enter |
| thinking, working, compacting, or waiting on an approval or a question | holds it in the agent's mailbox; the agent's Stop hook hands it over and keeps the agent going, or, if the agent stops without taking it, rook-link types it then |
| ended, or its pane now runs another session | gives up, and says why |

Two deliveries never land in one prompt: after typing one, rook-link waits for the agent to change state before typing the next. A message from another agent arrives with the sender's id and title, its team and thread, and the `rook message` line that answers it in that thread, or a note that no answer is wanted; a person's prompt arrives as written. Agents message only teammates; see [teams](teams.md).

## Interrupts, approvals and new sessions

A delivery carries a kind; the table above is a `prompt`'s. `rook link prompts off` turns all of these away too.

| Kind | What rook-link does |
|---|---|
| `interrupt` | presses Escape in the agent's pane while it thinks, works or compacts; an agent already stopped is left alone |
| `approve` | answers Claude Code's approval prompt, only while the agent waits on one: `once` presses 1, the prompt's first choice, allowing that one call; `deny` presses Escape. No other key is pressed, as the prompt's other choices vary; other harnesses are turned away |
| `playbook` | runs `rook-playbook install <playbook> --pane <pane> --project <its directory>` for the agent's pane in the background, as `Ctrl+t` `p` does, so the agent is told on its next turn; once loaded, a delivery with text goes on as a `prompt`, and one without is delivered. A failed load fails the delivery with rook-playbook's error |
| `spawn` | opens a window named `rook` in the tmux server the latest session started under (starting one if none runs), in the directory asked for, which it creates first, with any missing parents, when it does not exist yet (as a parent workdir's `<MMDD-name>` for a new agent); a directory it cannot create fails the delivery, running the harness with the first prompt in the user's login shell, which stays once the harness exits. The directory is marked trusted for the harness first, as the user would at its first screen (`hasTrustDialogAccepted` on the project in Claude Code's `.claude.json`, `trust_level = "trusted"` under the project in Codex's `config.toml`), so the session starts working without waiting on someone to answer whether they trust the folder. The new session reports itself through its hooks like any other. A launch's session gets `ROOK_LAUNCH` set to the launch id, which it reports as it starts, and has its playbook and skills installed into the directory and bound to its pane by `rook-playbook install --launch` before the harness starts |

What became of each delivery goes back to roost, which logs it (`delivered` or `undelivered`) and shows it in Rookery.

## Files

| | |
|---|---|
| `~/.local/share/rook/venv` | rook-link's Python, with the websockets package |
| `~/.local/state/rook/link.log` | what the service printed |
| `~/.local/state/rook/events.log` | what was sent, and when the link went up or down |
| `~/.local/state/rook/agent-panes/` | the pane each session started in |
| `~/.local/state/rook/mailbox/` | messages held for busy agents |
| `~/.local/state/rook/deliveries/` | the deliveries rook-link holds, until roost has heard what became of them |
