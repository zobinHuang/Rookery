---
name: start-agent
description: Propose starting a new code agent session on one of the user's machines (rooks), in a project directory, with a first prompt. Use when the user asks to start, spin up, launch or open an agent somewhere.
---

# Start an agent

1. Find the rook: `rook-client resource ls --kind rook --json`; it must be `online`. If the user did not say which, pick the one their other agents on that project run on (`rook-client agent status --all --json`: `rook` and `project`), and say so.
2. Find the directory: an absolute path on that rook. Take it from the user, or from the `cwd` of an earlier agent on the same project (`rook-client resource get agent <id>`). Never guess a path that no agent has used.
3. Write the first prompt as the user would type it to start the work: the task, the constraints they gave, and where to report. Empty is fine when the user only wants a session open.
4. Propose it: `rook-client propose spawn <rook> --cwd <dir> "<first prompt>"` (`--harness codex` if the user asked for codex). One proposal per session.
5. Tell the user in a line what you proposed and where; the Start button shows under your answer. Once started, the session reports itself and shows up in `rook-client agent status` within a few seconds.
