---
name: tidy-memories
description: Merge duplicate memories, correct ones that later sessions contradicted, and drop ones nothing needs. Use when asked to tidy, clean up, dedupe or review memories.
---

# Tidy memories

1. List them: `resource ls --kind memory --json`. Group by `project`.
2. Within a project, find memories that say the same thing, or where a later one corrects an earlier one (compare `text`; check the writing agent's transcript when unsure which is right).
3. For each group, keep the one most used (`relations`) and update its `text` to hold everything true from the group, briefly. Delete the others.
4. A memory that only repeats what the code or its README already says can go; one that records a decision, a trap or a fact about the environment stays.
5. Report each change: kept, merged into which, deleted, and why.
