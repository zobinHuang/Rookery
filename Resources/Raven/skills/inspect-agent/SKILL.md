---
name: inspect-agent
description: Find out what one code agent is doing or did: its task, its latest steps, what it changed, and where it is stuck. Use when the user names an agent (@agent/...) or asks what an agent is up to.
---

# Inspect one agent

1. Find the agent: from the `@agent/...` the request names, or by title in `rook-client agent status --all --json`. If several match, say which ones and ask.
2. `rook-client agent tail <id> --steps 60` for its latest steps; go further back (`--steps 200`) only if the task is not clear yet.
3. Read from the steps:
   - the task it was given, from the user's latest prompts;
   - what it did: files it edited, commands it ran, tests and their outcome;
   - where it stands: working, done, or waiting, and on what.
4. If it has subagents, `rook-client resource relations agent <id>` lists them (`spawned`); tail one only if it matters to the answer.
5. Answer in a few lines: what it is on, what it has done, and what, if anything, it needs from the user. Quote the agent's own question when it asked one. Change nothing.
