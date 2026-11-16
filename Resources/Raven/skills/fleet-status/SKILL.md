---
name: fleet-status
description: Report on the fleet of code agents now: which are working, which wait on the user and for what, which stopped on an error or a usage limit, and which rooks are offline. Use for "how are my agents", "what's stuck", "who needs me" and the like.
---

# Report the fleet's status

1. `rook-client agent status --json`. Each row is a live session; its subagents are counted under it.
2. For every row with `needs_person` (`needs_approval`, `needs_input`, `error`, `rate_limited`), read what it is waiting on with `rook-client agent tail <id> --steps 12`: the question it asked, the tool it wants approved, the error, or when its limit resets.
3. Note sessions whose rook is offline (`rook_online` false): they cannot be reached.
4. Answer, most urgent first:
   - **Needs you**: one line each, the agent's title, its rook, and exactly what it waits on, in a sentence.
   - **Working**: one line each, the title and what it is on, from its latest steps only if the user asked for detail.
   - **Idle or done**: a count, and their titles if there are few.
   - Offline rooks, if any.
5. Keep it short; no tables unless the user asks. Change nothing.
