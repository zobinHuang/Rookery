---
name: rookery-resources
description: Reference for reading and changing roost's resources (agents, skills, playbooks, memories), their relations, the event log and agent transcripts with rook-client. Read before running any rook-client command.
---

# roost resources with rook-client

Every command prints JSON unless noted. `$ROOKERY_AGENT_ID` is your own agent id.

## Read

    rook-client resource kinds                                # the kinds roost manages
    rook-client resource ls --kind memory --json              # a kind's resources, last used first; --q text filters
    rook-client resource get skill <id>                       # one resource with its attributes
    rook-client resource relations                            # every relation
    rook-client resource relations agent <id>                 # those touching one resource
    rook-client resource events --limit 100                   # the latest events
    rook-client resource transcript <agent id> --last 300     # an agent session's conversation, as text

A relation is `source --verb--> target` with how often and when it last happened. Verbs: `uses` (an agent used a skill), `mounts` (it loaded a playbook's skill), `follows` (it follows a playbook), `wrote` (it wrote a memory), `spawned` (a subagent), `messaged`, `created`, `updated`, `depends_on`.

Agents' attributes include `state`, `harness`, `cwd`, `git_branch` and `parent` (for a subagent). Memories have `text`, `path` and `project`. Skills have `description`, `repo_url`, `skill_path`. Playbooks have `description`, `prompt` and `skills` (pins: a skill id, or `{"skill_id": ..., "pin": ...}`).

## Change

Always pass `--as-agent $ROOKERY_AGENT_ID`.

    # a memory, or any kind but skills and playbooks: a name and attributes
    rook-client resource create memory --name "payments test fixtures" --attr text="Use the stripe-mock container." --attr project=payments --as-agent $ROOKERY_AGENT_ID
    rook-client resource update memory <id> --attr text="..." --as-agent $ROOKERY_AGENT_ID
    rook-client resource delete memory <id> --as-agent $ROOKERY_AGENT_ID

    # a skill: name, description or default_ref
    rook-client resource update skill <id> --body '{"description": "..."}' --as-agent $ROOKERY_AGENT_ID

    # a playbook: name, description, prompt, skills (replaces the list)
    rook-client resource create playbook --body '{"name": "Backend feature", "description": "...", "prompt": "...", "skills": ["<skill id>"]}' --as-agent $ROOKERY_AGENT_ID
    rook-client resource update playbook <id> --body '{"prompt": "..."}' --as-agent $ROOKERY_AGENT_ID

`--body` takes the whole request as JSON; `--name` and `--attr KEY=VALUE` add to it. A playbook may only pin skills roost already knows (`ls --kind skill`); a skill seen in use but never registered has `discovered: true` and no repository, and cannot be pinned.

If a command fails, read roost's answer: it says what was wrong.
