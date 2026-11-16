# Resources

Everything Rookery manages about code agents is a resource, of one of a few kinds; what happens to resources is an event; and when one resource acts on another, the event draws a relation between them. roost holds all three, rook reports events from the agents' hooks, and the app reads and subscribes. This document is the contract the three are written against.

## Kinds

| Kind | What it is | Its attributes | Where it comes from |
|---|---|---|---|
| `agent` | One code agent session, or a subagent it spawned | `state`, `title`, `harness`, `rook_name`, `tab`, `machine`, `cwd`, `git_branch`, `account`, `transcript_path`, `parent`, `opened_at`, `closed_at` | rook's hooks |
| `skill` | Instructions for using a tool | `source`, `repo_url`, `skill_path`, `default_ref`, `versions`, `description`; `discovered` when first seen in use rather than registered | the skill index; agents using or writing skills |
| `playbook` | A standard way to solve one kind of problem | `prompt`, `skills` (pins), `description` | the playbook index; the maintenance agent |
| `memory` | Details of a particular problem an agent wrote down to keep | `text`, `path`, `project` | agents writing into their own memory directory |
| `rook` | A machine running agents under rook | `online`, `machine`, `accepts_prompts`, `connected_at`, `disconnected_at` | the live link |

`GET /v1/kinds` lists them; a new kind is one more entry in `ResourceKinds` (`server/roost/resources.py`), and the generic API, the board and the lists take it from there.

Every resource has `kind`, `id`, `name`, `attributes`, `origin` (the resource that made it, usually an agent), and `created_at`, `updated_at` and `last_used_at`. `last_used_at` orders the board's columns: whatever was used last rises to the top.

## Agents are sessions

An agent is one session of one harness, and its id is the session's id; nothing ties it to a tmux pane, because a pane can switch agents and a reboot loses tmux's state. Its name is `<rook name>/<tab name>`, from the name rook asks for at setup and the tmux tab it runs in. A subagent's id is `<session id>~<subagent id>`, its `parent` and `origin` are the session, and the parent gets a `spawned` relation to it.

## Events

```json
{"seq": 18342, "at": "2026-11-15T14:30:12.004+00:00",
 "actor": {"kind": "agent", "id": "a07f54b5-…"},
 "verb": "uses",
 "object": {"kind": "skill", "id": "review"},
 "detail": {}}
```

Events only ever append, and `seq` only grows, so a reader resumes after the last one it saw. A batch posted to `POST /v1/events` applies all or nothing. A reported object may name a resource by `kind` and `name` instead of `id`: it is matched by name, or created and marked `discovered`.

| Verb | Object | Effect |
|---|---|---|
| `started` | — | creates or refreshes the agent from `detail` (the attribute fields above, `name`, `parent`); state `idle` |
| `state` | — | sets the agent's state from `detail.state`, and its title from `detail.title` when given |
| `renamed` | — | sets the agent's `title`, the session's title as its transcript gives it (a title the user gave, else one the harness made up); roost logs it whenever an uploaded transcript names its session anew, and fills it in when an agent starts after its transcript arrived |
| `ended` | — | state `ended`, `closed_at` set |
| `uses`, `mounts`, `follows`, `spawned`, `wrote`, `created`, `updated`, `depends_on` | required | draws or counts the relation from actor to object, and marks the object used |
| `created`, `updated`, `deleted` by a person | required | logged with the actor `{"kind": "person", "id": "user"}`; no relation |
| `messaged` | the agent | a person or an agent sent the agent text (`detail.delivery`, `detail.preview`); a relation when an agent sent it |
| `connected`, `disconnected` | — | a rook opened or lost the live link; sets its `online` |
| `delivered`, `undelivered` | the agent | the rook got a delivery to the agent, or could not (`detail.reason`) |

A change made through the resource API is logged as `created`, `updated` or `deleted`, by the agent the request names as `actor`, or else by a person.

## States

The tmux status bar keeps its three states (busy, wait, idle); roost gets ten, one crow animation each.

| State | Claude Code | codex |
|---|---|---|
| `idle` | SessionStart | SessionStart |
| `thinking` | UserPromptSubmit | UserPromptSubmit |
| `working` | PreToolUse | PreToolUse |
| `needs_approval` | Notification `permission_prompt` | PermissionRequest |
| `needs_input` | Notification `elicitation_dialog` | — |
| `compacting` | PreCompact | — |
| `done` | Stop | Stop |
| `error` | StopFailure | — |
| `rate_limited` | StopFailure about a usage limit | — |
| `ended` | SessionEnd | SessionEnd |

A harness without an event for a state simply never reports it; the crow stays in the state before.

## Relations rook reports

| From the hook | Event |
|---|---|
| PreToolUse of the `Skill` tool | agent `uses` the skill it names |
| PostToolUse of Write or Edit into the agent's memory directory (`~/.claude/projects/<project>/memory/`) | agent `wrote` the memory, with its text and path |
| PostToolUse of Write or Edit under `.claude/skills/<name>/` or `.agents/skills/<name>/` | agent `updated` the skill named by the directory |
| SubagentStart, SubagentStop | a subagent `started` with its parent; `ended` when it stops |
| A playbook told to a session (at SessionStart, or the first prompt after one is picked with `Ctrl+t` `p`) | agent `follows` the playbook, `mounts` each of its skills |
