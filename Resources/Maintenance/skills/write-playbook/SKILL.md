---
name: write-playbook
description: Write a new playbook, or rework one, from what the user describes; its steps name the skills they use. Use when asked to create, write, edit, improve, merge or split playbooks.
---

# Write a playbook

1. Read what exists: `resource ls --kind playbook --json` for playbooks on the same problem, which you improve rather than duplicate, and `resource ls --kind skill --json` for the skills you may use (not those `discovered`).
2. Settle the problem it is for, in a few words, as its `name`, and when an agent should follow it, in one sentence, as its `description`.
3. Write the steps as its `prompt`:
   - numbered, one a line, in the imperative, in the order the work goes;
   - a step that uses a skill names it with `@` and the skill's id or name (`2. Build the report with @pdf.`);
   - the checks that say the work is done, and the traps to avoid, are steps too.
4. Set `skills` to every skill a step names (by id), plus any the whole playbook needs; keep the pins an existing playbook already has unless the user asked otherwise.
5. Create it (`resource create playbook --body '{...}'`) or update it (`resource update playbook <id> --body '{...}'`), with `--as-agent`.
6. When a step needs a skill roost has not registered, say which, and that the user can add it by its address; do not make one up.
7. Report the playbook's id, its steps and its skills.
