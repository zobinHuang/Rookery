---
name: review-fleet
description: Answer questions about the fleet, such as which agents are stuck, what an agent did, which skills go unused, or what changed today, from resources, relations, events and transcripts. Use for any question about the agents rather than a change.
---

# Review the fleet

- Stuck agents: `state` of `needs_approval`, `needs_input`, `error` or `rate_limited`, or `working` with no event for a long while (`resource events`).
- What an agent did: its relations and its transcript (`--last` keeps it short).
- Unused skills or playbooks: those with no `uses`, `mounts` or `follows` relation, or none recently (`last_at`).
- What changed: `resource events --limit 200`, grouped by actor.

Answer briefly, naming agents by their `name` and giving the numbers. Change nothing unless asked.
