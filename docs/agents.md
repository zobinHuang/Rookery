# Agents

The sidebar's Agents mode shows every code agent rookd knows of, one crow each playing the state its session is in, and the content area shows one agent's conversation with a box to prompt it. What an agent is, and the events that move it between states, are in [resources](resources.md); how a prompt reaches its pane is in [rook's live link](../rook/docs/link.md).

## Following rookd

`FleetModel` (one for the app) holds the fleet. With an address in Settings and the token in the keychain (`KeychainSecret`, account `rookd-token`), it reads the agents and rooks over HTTP, then opens rookd's live link as a desktop and applies each event to `AgentFleet` (`RookeryCore`): a state or an end changes the agent in place, a new agent is fetched. When the link drops it shows the last fleet with a banner and retries, backing off from 2 to 60 seconds, then reads everything afresh, so nothing between the drop and the reconnect is missed.

`RookdClient` (`RookeryPlatform`) is the only code that speaks rookd's API.

## The sidebar

- Sessions only; a session's subagents fold under it behind a count.
- The user's groups first, then the rest by last activity, then those that ended, folded away.
- Groups are this Mac's own (`agent-groups.json` in the data directory): drag an agent onto a group, onto an agent in a group to put it before, onto New Group to start one, or onto Ungrouped to take it out; drag a group's header to reorder groups. Agents rookd forgot are pruned on every full read.
- A machine whose rook is offline dims its agents.

## The crows

`branding/` renders each state's loop into `Resources/Crow_<state>.png` (a strip of 64-pixel frames) and `Resources/Crows.json`. `CrowView` plays them through `PixelAnimationView`, the same layer the sidebar logo uses: a discrete keyframe animation on the layer's contents, scaled without smoothing, so the loops cost the app nothing while they play and stand still under Reduce Motion. At 32 points on a Retina screen a crow is drawn pixel for pixel.

## The agent's page

`AgentDetailView` reads the session's transcript from rookd every two seconds, only the bytes it has not seen, through `TranscriptReader` (`RookeryCore`), which understands Claude Code transcripts and codex rollouts and keeps what a person reads: the prompts, the answers and one line per tool call. Prompts typed in its box go to `POST /v1/messages`; under the box, the latest prompts show what became of them (waiting while the agent is busy, delivered, or failed and why).

## Checking it without a person

Seed a rookd of your own with agents (`POST /v1/events` with `started` and `state` events, a transcript through the session upload API) and render `StageView` offscreen with a `FleetModel` given an in-memory `SecretStore`, so the render never touches the keychain; see docs/development.md for the harness.

## Rookmaster

The console over everything rookd manages, opened from the top of the Agents sidebar. `FleetModel` keeps a `ResourceGraph` (`RookeryCore`) beside the fleet: every kind rookd lists, all their resources, the relations between them and the latest hundred events, read in full on connecting and kept current by the same live link.

- **Board** (`RookmasterBoard`): a column per kind, agents leftmost, each ordered by last use so what moved last rises, with an animation. Edges are the relations, drawn from the cards' frames (anchor preferences), thicker for relations that happened more often, coloured by verb; a subagent's edges are drawn from its session's card. Hovering or clicking a card brings forward it, its neighbours and the edges between them; double-clicking opens it. Lock freezes the order; the filters narrow by name, by time since last use, to live agents, and by kind.
- **A list per kind** (`RookmasterKindList`): search, and beside it the resource's relations (click one to go to the other end) and attributes. Memories and any new kind are edited as a name and an attributes object and can be deleted; skills and playbooks keep their own shape and are read-only here, as agents are.
- **Log** (`RookmasterLog`): the latest hundred events, newest at the bottom, following as they are logged, with a filter; it folds to its title bar.
