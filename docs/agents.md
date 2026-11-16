# Agents

The sidebar's Agents mode shows every code agent roost knows of, one crow each playing the state its session is in, and the content area shows one agent's conversation with a box to prompt it. What an agent is, and the events that move it between states, are in [resources](resources.md); how a prompt reaches its pane is in [rook's live link](../rook/docs/link.md).

## Following roost

`FleetModel` (one for the app) holds the fleet. With an address in Settings and the token in the keychain (`KeychainSecret`, account `roost-token`), it reads the agents and rooks over HTTP, then opens roost's live link as a desktop and applies each event to `AgentFleet` (`RookeryCore`): a state or an end changes the agent in place, a new agent is fetched. When the link drops it shows the last fleet with a banner and retries, backing off from 2 to 60 seconds, then reads everything afresh, so nothing between the drop and the reconnect is missed.

`RoostClient` (`RookeryPlatform`) is the only code that speaks roost's API.

## The sidebar

- Sessions only; a session's subagents fold under it behind a count.
- The user's teams first, then the rest by last activity, then those that ended, folded away.
- Teams are this Mac's own (`agent-teams.json` in the data directory; `agent-groups.json`, from when they were called groups, is read once): drag an agent onto a team, onto an agent in a team to put it before, onto New Team to start one, or onto Unassigned to take it out; drag a team's header to reorder teams. Agents roost forgot are pruned on every full read.
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

## Raven

The Rookmaster console's right-hand column asks Raven, Rookery's agent over the fleet, for something in plain words; `@` names a resource, completed from the graph (`Mentions` in `RookeryCore`), and the request carries each named resource's kind, name and id. `RavenAgent` runs Claude Code headless (`HeadlessAgent` in `RookeryPlatform`) in a workspace of its own under the data directory, laid out afresh for each request from the app's `Raven` resources (`Resources/Raven` in the repository):

- `CLAUDE.md`, its standing instructions, and `.claude/skills/`, Rookery's skills: `rookery-resources` (the command reference), `fleet-status`, `inspect-agent` and `triage-attention` (the agents' state, what one is doing, what waits on the user, through `rook-client agent status` and `agent tail`), `brief-agent` (a message to an agent, proposed), `register-skill`, `write-playbook`, `distill-playbook`, `tidy-memories`, `describe-skills` and `review-fleet`.
- `bin/rook-client`, the same client rook installs, and `config/rook/connect.json`, the app's roost address and token, readable by the user alone.

Claude Code runs with `--setting-sources project`, so neither the user's settings nor their hooks apply, and `--allowedTools "Bash(rook-client resource:*)" "Bash(rook-client agent:*)" "Bash(rook-client propose:*)" Skill WebFetch`: it reads and changes roost's resources, reads the agents' state and transcripts, loads its skills and reads a skill's own pages, and nothing else; in particular it cannot run `rook-client message`. What it would say to an agent it proposes with `rook-client propose message`, which checks the agent and prints the proposal without sending anything. The app finds each proposal in Raven's output and history (`RavenProposal` in `RookeryCore`) and shows it under the conversation with Send and Don't Send; sending posts the text to roost as the user and follows the delivery. Each decision is kept with the conversation (`RavenDecision`) and told to Raven at the start of its next request.

To check the plumbing without calling a model, set `executableOverride` to a script that prints stream-json lines and runs `rook-client` itself, and `workspaceOverride` to a scratch directory.
