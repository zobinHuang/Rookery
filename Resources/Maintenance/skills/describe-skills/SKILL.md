---
name: describe-skills
description: Write the missing descriptions of registered skills from how agents used them. Use when asked to describe, document or fill in skills.
---

# Describe skills

1. `resource ls --kind skill --json`; take those with an empty `description` and not `discovered`.
2. For each, find agents that used it (`resource relations skill <id>`), and read the parts of their transcripts around the `[tool Skill]` line to see what it was for.
3. Write one sentence saying when to use it, starting with a verb: "Review a pull request for security issues before merging."
4. `resource update skill <id> --body '{"description": "..."}' --as-agent $ROOKERY_AGENT_ID`.
5. Report the descriptions you wrote.
