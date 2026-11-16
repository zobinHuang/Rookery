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

Two deliveries never land in one prompt: after typing one, rook-link waits for the agent to change state before typing the next. A message from another agent arrives with the sender's id and the `rook message` line that answers it; a person's prompt arrives as written.

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
