---
name: triage-attention
description: Go through every agent that waits on the user, say what each needs, and propose an answer where one is clear. Use for "who needs me", "go through what's waiting", "unblock my agents".
---

# Triage what waits on the user

1. `rook-client agent status --json`; take the rows with `needs_person`.
2. For each, `rook-client agent tail <id> --steps 15` and find exactly what it waits on:
   - `needs_approval`: the tool call it wants to run, and why;
   - `needs_input`: its question;
   - `error`: the error and what it was doing;
   - `rate_limited`: nothing to answer; say when the limit resets if the transcript says.
3. Where the answer is clear from the transcript and the user's earlier instructions, propose it with `rook-client propose message <id> "<answer>"`, as `brief-agent` writes one. Where it is a real decision for the user (a destructive command, a choice between approaches, a cost), propose nothing; put the question to the user plainly.
4. For `needs_approval`, read the exact call it wants to run. Where it plainly serves what the user asked and touches nothing it should not, propose allowing it once: `rook-client propose approve <id> --choice once`. Where it is destructive, outside the task, or unclear, propose declining (`--choice deny`) or nothing, and say why. Never more than once per call; there is no "always".
5. Answer with one short block per agent, most urgent first: the title, what it waits on, and what you proposed or what the user must decide.
