---
name: team-report
description: Report what a team of agents is doing, what its members told one another, and where it is stuck or waiting on the user. Use when the user asks how a team is going, what agents discussed, or why a team is stuck.
---

# Report on a team

1. Read the team: `rook-client team roster <team>`: its goal, and each member's role, duty, focus, state and host.
2. Read what they said to one another: `rook-client resource events --limit 500`, keeping the `messaged` events between its members, and for each member that matters, `rook-client agent tail <agent id>` for its latest steps.
3. Look for what blocks the team:
   - members waiting on the user (approval, input, an error or a rate limit), from their state;
   - messages roost held for the user (a `messaged` event whose detail carries `held`); the user lets them go or cancels them in Rookery's Teams tab;
   - two members going back and forth on one question without settling it;
   - a member whose focus no longer fits its duty or the goal.
4. Answer in a few lines: where the team stands against its goal, who does what now, what is stuck and why, and what the user could do, proposing it where you can (`brief-agent`, `triage-attention`, `manage-teams`).
