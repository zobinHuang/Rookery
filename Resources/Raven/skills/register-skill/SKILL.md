---
name: register-skill
description: Register a skill with roost from its address and describe it from its SKILL.md. Use when the user gives a skill's GitHub or GitLab address, or asks to add, register or track a skill.
---

# Register a skill

1. Take the address as the user gave it: a page of the skill's directory or of its SKILL.md on GitHub or GitLab (`https://github.com/owner/repo/tree/main/skills/pdf`), or `owner/repo@path#ref`.
2. Read its SKILL.md with `rook-client resource skill-file '<address>'` for its name and what it is for: roost reads it with the token the user registered for the repository's host, so this works for private repositories too. If roost cannot read the repository, tell the user to add a token for its host in Settings, Roost, Git Credentials. If there is none, do not register it: an agent loads a skill only from a directory holding a SKILL.md that starts with a `name` and a `description`. Tell the user so, and that the repository should keep each skill in a directory of its own (`skills/<name>/SKILL.md`, as `npx skills` expects); roost refuses a path to any other Markdown file.
3. Register it: `rook-client resource create skill --body '{"source": "<address>", "description": "<one sentence on when to use it>"}' --as-agent $ROOKERY_AGENT_ID`. roost resolves the ref to a commit; if it cannot read the repository, report what it said.
4. If a skill with the same repository and path is registered already, roost refreshes it instead; say so.
5. Report the skill's id, the commit it was resolved to and the description you wrote, and which playbooks could use it (`resource ls --kind playbook --json`).
