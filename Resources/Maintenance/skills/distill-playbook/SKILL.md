---
name: distill-playbook
description: Turn how agents actually solved a kind of problem into a playbook, from their sessions' transcripts and the skills they used. Use when asked to distill, extract or write a playbook from sessions or agents.
---

# Distill a playbook from sessions

1. Find the sessions: the agents the user named, or those whose transcripts show the kind of problem (`resource ls --kind agent --json`, then `resource transcript <id>`).
2. Read each transcript. Note what the agent was asked, the steps that worked, the mistakes it had to undo, and the checks that told it it was done.
3. Find the skills they used: `resource relations agent <id>`, verb `uses` or `mounts`. Keep those rookd has registered (not `discovered`).
4. Look for an existing playbook for the same problem (`resource ls --kind playbook --json`). Improve it rather than adding a second.
5. Write the playbook:
   - `name`: the problem, in a few words ("Backend feature with migrations").
   - `description`: when to load it, in one sentence.
   - `prompt`: standing instructions in the imperative, one line each: the order to work in, the checks to run, the traps the sessions fell into. No narrative, no history of the sessions.
   - `skills`: the registered skills from step 3 that the work needed.
6. Create or update it with `--as-agent`, then report the playbook's id, what it says, and which sessions it came from.
