---
name: review-fleet
description: Answer questions about how the fleet uses what roost holds, such as which skills or playbooks go unused, what an agent touched, or what changed today, from resources, relations and events. For the agents' own state, who is stuck or what one is doing, use fleet-status or inspect-agent.
---

# Review how the fleet uses roost

- What an agent touched: `rook-client resource relations agent <id>`: the skills it used, the playbooks it followed, the memories it wrote, the subagents it spawned.
- Unused skills or playbooks: those with no `uses`, `mounts` or `follows` relation, or none recently (`last_at`).
- What changed: `rook-client resource events --limit 200`, grouped by actor.

Answer briefly, naming agents by their title and giving the numbers. Change nothing unless asked.
