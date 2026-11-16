---
name: rookery-resources
description: Reference for reading and changing roost's resources (agents, skills, playbooks, memories), their relations, the event log and agent transcripts with rook-client. Read before running any rook-client command.
---

# roost resources with rook-client

Every command prints JSON unless noted. `$ROOKERY_AGENT_ID` is your own agent id.

## The agents

    rook-client agent status                  # every live session: those needing a person first, then working, then the rest
    rook-client agent status --all --json     # ended ones too, as JSON: id, title, state, needs_person, rook, rook_online, project, branch, subagents, last_used_at
    rook-client agent tail <agent id>         # what it said and did lately, as text; --steps N for more or fewer

    rook-client propose message <agent id> "text"   # propose text for the user to send it; nothing is sent

A subagent's id is `<session id>~<agent id>`; `agent tail` reads its own transcript. States: `idle`, `thinking`, `working`, `compacting`, `done`, `needs_approval`, `needs_input`, `error`, `rate_limited`, `ended`. The first four need nothing; `needs_*` waits on a person.

## Read

    rook-client resource kinds                                # the kinds roost manages
    rook-client resource ls --kind memory --json              # a kind's resources, last used first; --q text filters
    rook-client resource get skill <id>                       # one resource with its attributes
    rook-client resource relations                            # every relation
    rook-client resource relations agent <id>                 # those touching one resource
    rook-client resource events --limit 100                   # the latest events
    rook-client resource transcript <agent id> --last 300     # a whole session's conversation, as text; prefer agent tail

A relation is `source --verb--> target` with how often and when it last happened. Verbs: `uses` (an agent used a skill), `mounts` (it loaded a playbook's skill), `follows` (it follows a playbook), `wrote` (it wrote a memory), `spawned` (a subagent), `messaged`, `created`, `updated`, `depends_on`.

Agents' attributes include `state`, `harness`, `cwd`, `git_branch` and `parent` (for a subagent). Memories have `text`, `path` and `project`. Skills have `description`, `repo_url`, `skill_path`. Playbooks have `description`, `prompt` and `skills` (pins: a skill id, or `{"skill_id": ..., "pin": ...}`).

## Change

Always pass `--as-agent $ROOKERY_AGENT_ID`.

    # a memory, or any kind but skills and playbooks: a name and attributes
    rook-client resource create memory --name "payments test fixtures" --attr text="Use the stripe-mock container." --attr project=payments --as-agent $ROOKERY_AGENT_ID
    rook-client resource update memory <id> --attr text="..." --as-agent $ROOKERY_AGENT_ID
    rook-client resource delete memory <id> --as-agent $ROOKERY_AGENT_ID

    # a skill: register it from its address, as copied from GitHub or GitLab, or owner/repo@path#ref
    rook-client resource create skill --body '{"source": "https://github.com/owner/repo/tree/main/skills/pdf", "description": "..."}' --as-agent $ROOKERY_AGENT_ID
    # then change its name, description or default_ref
    rook-client resource update skill <id> --body '{"description": "..."}' --as-agent $ROOKERY_AGENT_ID

    # a playbook: name, description, prompt, skills (replaces the list)
    rook-client resource create playbook --body '{"name": "Backend feature", "description": "...", "prompt": "...", "skills": ["<skill id>"]}' --as-agent $ROOKERY_AGENT_ID
    rook-client resource update playbook <id> --body '{"prompt": "..."}' --as-agent $ROOKERY_AGENT_ID

A playbook's `prompt` is its steps, one a line, in the imperative. A step that uses a skill names it with `@` and the skill's id or its name with dashes for spaces (`2. Write the migration with @db-migrations.`), and the skill is in the playbook's `skills` too, so agents that follow it load it.

`--body` takes the whole request as JSON; `--name` and `--attr KEY=VALUE` add to it. A playbook may only pin skills roost already knows (`ls --kind skill`); a skill seen in use but never registered has `discovered: true` and no repository, and cannot be pinned.

If a command fails, read roost's answer: it says what was wrong.
