# Agents

The sidebar's Agents mode shows every code agent roost knows of, one crow each playing the state its session is in, and the content area shows one agent's conversation with a box to prompt it. What an agent is, and the events that move it between states, are in [resources](resources.md); how a prompt reaches its pane is in [rook's live link](../rook/docs/link.md).

## Following roost

`FleetModel` (one for the app) holds the fleet. With an address in Settings and the token in the keychain (`KeychainSecret`, account `roost-token`), it reads the agents and rooks over HTTP, then opens roost's live link as a desktop and applies each event to `AgentFleet` (`RookeryCore`): a state or an end changes the agent in place, a new agent is fetched. When the link drops it shows the last fleet with a banner and retries, backing off from 2 to 60 seconds, then reads everything afresh, so nothing between the drop and the reconnect is missed.

`RoostClient` (`RookeryPlatform`) is the only code that speaks roost's API.

## The sidebar

- Sessions only; a session's subagents fold under it behind a count.
- The user's teams first, then the rest by last activity, then those that ended, folded away.
- Teams live on roost ([teams](../rook/docs/teams.md)), so their agents know them too; an agent may be in several, and shows under each, tagged with the others. This Mac keeps only the layout in `agent-teams.json`: the order of the teams and of the agents in each, and which are folded. Teams made here before roost held them are carried over to it once. Drag an agent onto a team to add it, holding Option to move it out of the team it was dragged from; onto an agent in a team to put it before; onto New Team to start one; or onto Unassigned to take it out of the team it came from. Drag a team's header to reorder teams. A change shows at once and is written to roost; if roost refuses it, the sidebar says why and takes roost's teams back.
- Each agent's row shows what it works on now, or its role, as it set them with `rook me`.
- A machine whose rook is offline dims its agents.

## The crows

`branding/` renders each state's loop into `Resources/Crow_<state>.png` (a strip of 64-pixel frames) and `Resources/Crows.json`. `CrowView` plays them through `PixelAnimationView`, the same layer the sidebar logo uses: a discrete keyframe animation on the layer's contents, scaled without smoothing, so the loops cost the app nothing while they play and stand still under Reduce Motion. At 32 points on a Retina screen a crow is drawn pixel for pixel.

## The agent's page

`AgentDetailView` reads the session's transcript from roost every two seconds, only the bytes it has not seen, through `TranscriptReader` (`RookeryCore`), which understands Claude Code transcripts and codex rollouts and keeps what a person reads: the prompts, the answers and one line per tool call. Prompts typed in its box go to `POST /v1/messages`; under the box, the latest prompts show what became of them (waiting while the agent is busy, delivered, or failed and why).

## Checking it without a person

Seed a roost of your own with agents (`POST /v1/events` with `started` and `state` events, a transcript through the session upload API) and render `StageView` offscreen with a `FleetModel` given an in-memory `SecretStore`, so the render never touches the keychain; see docs/development.md for the harness.

## Rookmaster

The console over everything roost manages, opened from the top of the Agents sidebar. `FleetModel` keeps a `ResourceGraph` (`RookeryCore`) beside the fleet: every kind roost lists, all their resources, the relations between them and the latest hundred events, read in full on connecting and kept current by the same live link.

- **Board** (`RookmasterBoard`): a column per kind, agents leftmost, each ordered by last use so what moved last rises, with an animation. Edges are the relations, drawn from the cards' frames (anchor preferences), thicker for relations that happened more often, coloured by verb; a subagent's edges are drawn from its session's card. Hovering or clicking a card brings forward it, its neighbours and the edges between them; double-clicking opens it. Lock freezes the order; the filters narrow by name, by time since last use, to live agents, and by kind.
- **A list per kind** (`RookmasterKindList`), with an editor beside it (`ResourceEditors.swift`):
  - skills are added by pasting their address (a GitHub or GitLab page of the skill's directory or its SKILL.md, or `owner/repo@path#ref`); the editor shows where the skill lives and the commit roost resolved, and changes its name, description and tracked ref, refreshes it, or removes it;
  - playbooks are created, edited and deleted: what they are for, their steps, and the skills they load. A step names a skill it uses with `@`; saving pins every skill the steps name (`PlaybookSteps` in `RookeryCore`), beside those added by hand;
  - memories are created, edited and deleted: their name, project and text;
  - agents are read-only, and any other kind is edited as a name and an attributes object.
- **Log** (`RookmasterLog`): the latest hundred events, newest at the bottom, following as they are logged, with a filter; it folds to its title bar.

## Hosts and new agents

The Hosts tab of Rookmaster lists the concrete hosts of `~/.ssh/config` (patterns and `Match` blocks name none; `Include` is followed), each with the rook it runs: the one the user chose, else a rook named as the host or its short host name. A host's page checks over ssh what it has for agents (tmux, claude, codex, rook, and whether rook reports to a roost), installs rook where it has none (after asking: it runs rook's `setup.sh --name` and `rook connect` there, the token going over ssh's input, never a command line), and keeps the host's workdirs: a directory, browsable over ssh, with the harness, playbook, skills, role and teams an agent started there begins with. Hosts' settings and workdirs live in `hosts.json` in the app's data directory, since only this Mac's ssh configuration reaches the hosts. ssh runs with `BatchMode`, so a host that asks for a password fails rather than waiting.

New Agent, in the Agents list, on a host's page and on each workdir, starts an agent through roost rather than ssh: a spawn with a launch id ([the API](../server/API.md#messages)), which the host's rook-link starts in tmux after installing the playbook and skills; the session names its launch as it starts, and roost gives it its role and teams. Until it reports in, the launch shows as starting under the button; a rook that could not start it, or a session that never reports in within 90 seconds, shows why, naming the pane it was started in: a session in a folder Claude Code has not trusted waits there for a person to answer its trust prompt.

## Teams

The Teams tab of Rookmaster shows each team: its goal, which its agents are told; its members' cards with their role, focus, state and host, and their duty in the team, which the user edits in place; the messages its agents sent one another and to the whole team, oldest first; a box to speak to the whole team as the user; and the limits past which roost holds a message. A held message shows its reason with Cancel and Let It Go; the tab and the team's row count those still held. An agent's page shows its role, which the user may change, its focus and its teams.

## Raven

The Rookmaster console's right-hand column asks Raven, Rookery's agent over the fleet, for something in plain words; `@` names a resource, completed from the graph (`Mentions` in `RookeryCore`), and the request carries each named resource's kind, name and id. `RavenAgent` runs Claude Code headless (`HeadlessAgent` in `RookeryPlatform`) in a workspace of its own under the data directory, laid out afresh for each request from the app's `Raven` resources (`Resources/Raven` in the repository):

- `CLAUDE.md`, its standing instructions, and `.claude/skills/`, Rookery's skills: `rookery-resources` (the command reference), `fleet-status`, `inspect-agent` and `triage-attention` (the agents' state, what one is doing, what waits on the user, through `rook-client agent status` and `agent tail`), `brief-agent` (a message or an interrupt for an agent, proposed), `start-agent` (a new agent on a host or workdir, with its playbook, skills, role and teams, proposed), `manage-teams` (a new team, a member and its duty, proposed), `team-report` (where a team stands and what blocks it), `register-skill`, `write-playbook`, `distill-playbook`, `tidy-memories`, `describe-skills` and `review-fleet`.
- `bin/rook-client`, the same client rook installs, and `config/rook/connect.json`, the app's roost address and token, readable by the user alone.
- `config/rook/hosts.json`, the user's ssh hosts with their rooks and workdirs, which `rook-client host list` reads: they live on this Mac, not on roost.

Claude Code runs with `--setting-sources project`, so neither the user's settings nor their hooks apply, and `--allowedTools "Bash(rook-client resource:*)" "Bash(rook-client agent:*)" "Bash(rook-client propose:*)" "Bash(rook-client host:*)" "Bash(rook-client team list:*)" "Bash(rook-client team roster:*)" Skill WebFetch`: it reads and changes roost's resources, reads the agents' state and transcripts, loads its skills and reads a skill's own pages, and nothing else; in particular it cannot run `rook-client message`. What it would do to an agent or on a rook it proposes with `rook-client propose`: `message`, `interrupt`, `approve` (allow the waiting call once, or decline it) or `spawn` (a new session in a directory on a rook); each checks its agent or rook and prints the proposal without doing anything. The app finds each proposal in Raven's output and history (`RavenProposal` in `RookeryCore`) and shows it under the conversation with a button that carries it out and Not Now; carrying it out posts it to roost as the user, as a delivery of its kind for the rook to perform (rook/docs/link.md), and follows the delivery. Each decision is kept with the conversation (`RavenDecision`) and told to Raven at the start of its next request.

To check the plumbing without calling a model, set `executableOverride` to a script that prints stream-json lines and runs `rook-client` itself, and `workspaceOverride` to a scratch directory.
