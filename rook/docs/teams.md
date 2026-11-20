# Teams

Agents in a team know one another and message one another through roost. A team, its goal and who is in it with what duty live on roost; the user makes them in Rookery, and a launch can put a new session in one as it starts. An agent may be in several teams.

```bash
rook team list                      # the teams the agent in this pane is in
rook team roster <team>             # who is in one: role, duty, what each does now, where, in what state
rook team send <team> "..."         # a message to every other member
rook message <agent> "..."          # a message to one teammate
rook message <agent> --thread <id> --no-reply "..."
rook me role "owner of billing"     # who this agent is to its teammates
rook me focus "invoice migration"   # what it works on now
rook inbox                          # what it received and sent lately
```

## What an agent is told

Claude Code is told through its hooks. As a session starts, and again after a compaction, its `SessionStart` hook adds every team it is in to the conversation: the goal, each member's id, title, host, directory and state, its role, its duty in the team and its focus, and the commands above. Before each prompt, at most once a minute, its `UserPromptSubmit` hook adds what changed since: who joined or left, a new duty, a new goal. A session in no team is told nothing. Each read waits on roost for three seconds at most and never holds the agent up beyond that.

`setup.sh` installs the `rook-team` skill into Claude Code's skills, which says when to message a teammate and how: everything in one message, every question at once, `--no-reply` when no answer is needed, no answers that only acknowledge, and answers inside the thread they belong to. codex can message and be messaged, but is not told of its teams yet.

## Raven

The user can put one of Raven's conversations in a team from Rookery, to direct the team or ask it questions. Its card names it as Raven, the user's assistant, speaking for the user, and the messages it sends say so; the skill tells agents to take its asks as the user's. Raven runs outside tmux, so it names itself to `rook-client` with `ROOK_AGENT_ID`. Like any member it messages only its teammates; their answers wait on roost under the rook `rookery` until Rookery reads them and wakes the conversation.

## Threads and limits

Every message belongs to a thread; an answer names the thread it answers with `--thread`, and the message the receiving agent reads says which thread to answer in. A team has no limits by default; the skill keeps agents from answering each other without end. The user can turn limits on for a team in Rookery, and roost then holds a message for them to release or cancel when an agent goes past them: a thread past 20 messages, or 30 messages from one agent in 10 minutes, unless changed. See [the API](../../server/API.md#messages).

## Launches

A session Rookery or Raven starts through roost can carry a launch: a playbook and further skills to install first, a role, and the teams to join with their duties. rook-link installs them with `rook-playbook install --launch` and starts the harness with `ROOK_LAUNCH` set; the session's first hook sends its start to roost at once, which puts it in its teams, and then tells it of them.
