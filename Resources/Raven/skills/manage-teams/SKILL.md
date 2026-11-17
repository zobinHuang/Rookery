---
name: manage-teams
description: Propose making a team of agents, putting agents in a team with a duty, giving a member a new duty, or taking one out. Use when the user asks to group agents, pair them up, have agents work together or coordinate, or change who does what in a team.
---

# Manage teams

Agents in a team are told of one another, each member's role, duty and focus, and can message one another through rook. An agent may be in several teams.

1. See what is there: `rook-client team list` for every team with its members, `rook-client team roster <team>` for one, and `rook-client agent status` for the agents.
2. A new team: `rook-client propose create-team <id> --name "<name>" --goal "<what it works toward>"`. The id is lowercase letters, digits and dashes, from the name. Write the goal so every member can act on it.
3. Each member: `rook-client propose join <team id> <agent id> --duty "<what it does in this team>"`. A duty is one line, specific to the team: "the refund API and its tests", not "backend". Proposing join for a member gives it the new duty.
4. Taking one out: `rook-client propose leave <team id> <agent id>`.
5. Propose a new team before its members; the user carries them out in order. Then say in a few lines what the team is for and who does what. To start a new agent straight into a team, use `start-agent` with `--team`.

You cannot set an agent's role or focus. Rookery writes both from each agent's work and keeps them up to date; an agent may set its own with `rook me role` and `rook me focus`, and the user can set a role on the agent's page; those are kept as written.
