import json
import secrets
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from roost.errors import NotFoundError, ValidationError
from roost.events import Event, EventLog, EventVerbs
from roost.resources import Resource, ResourceKinds, ResourceRef, ResourceStore
from roost.teams import TeamLimits, TeamRoster


@dataclass
class Delivery:
    """Something on its way to an agent through its rook: text to type, from a person or another agent; an
    interrupt; an answer to the agent's approval prompt; or, for a rook rather than an agent, a new session
    to start."""

    KIND_PROMPT = "prompt"
    KIND_INTERRUPT = "interrupt"
    KIND_APPROVE = "approve"
    KIND_SPAWN = "spawn"
    SET_AGENT_KINDS = frozenset({KIND_PROMPT, KIND_INTERRUPT, KIND_APPROVE})
    APPROVE_ONCE = "once"
    APPROVE_DENY = "deny"
    SET_APPROVE_CHOICES = frozenset({APPROVE_ONCE, APPROVE_DENY})
    SET_SPAWN_HARNESSES = frozenset({"claude", "codex"})

    STATUS_PENDING = "pending"
    STATUS_SENT = "sent"
    STATUS_WAITING = "waiting"
    STATUS_DELIVERED = "delivered"
    STATUS_FAILED = "failed"
    STATUS_EXPIRED = "expired"
    """Held by roost for the user to release or cancel, as one agent went past its team's limits."""
    STATUS_HELD = "held"
    STATUS_CANCELLED = "cancelled"
    SET_OPEN_STATUSES = frozenset({STATUS_PENDING, STATUS_SENT, STATUS_WAITING})
    SET_REPORTED_STATUSES = frozenset({STATUS_WAITING, STATUS_DELIVERED, STATUS_FAILED})

    id: str
    agent_id: str
    rook_name: str
    text: str
    sender: ResourceRef
    status: str
    map_detail: dict[str, object] = field(default_factory=dict)
    created_at: str = ""
    updated_at: str = ""
    kind: str = KIND_PROMPT
    map_options: dict[str, object] = field(default_factory=dict)

    def is_open(self) -> bool:
        """Whether the delivery may still reach its agent."""
        return self.status in self.SET_OPEN_STATUSES

    def as_payload(self) -> dict[str, object]:
        """Render the delivery as JSON.

        Returns:
            a mapping of every recorded field
        """
        return {
            "id": self.id,
            "agent_id": self.agent_id,
            "rook_name": self.rook_name,
            "text": self.text,
            "sender": self.sender.as_payload(),
            "status": self.status,
            "detail": self.map_detail,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "kind": self.kind,
            "options": self.map_options,
        }

    def target(self) -> ResourceRef:
        """What the delivery is for: its agent, or its rook for a new session."""
        if self.kind == self.KIND_SPAWN:
            return ResourceRef.of(ResourceKinds.ROOK.name, self.rook_name)
        return ResourceRef.of(ResourceKinds.AGENT.name, self.agent_id)


class DeliveryStore:
    """The deliveries the server holds until the rook running their agent takes them, and what became of
    each. A delivery is routed by the rook its agent runs under, which for a subagent is its parent's.

    An agent messages only agents it shares a team with, one at a time or the whole team at once. Every
    prompt belongs to a thread, which an answer carries on; an agent that goes past its team's limits, too
    many turns in one thread or too many messages in a while, has its message held for the user.
    """

    DELIVERY_TEXT_MAX_BYTES = 64 * 1024
    DELIVERY_TTL = timedelta(days=1)
    DELIVERY_ID_BYTES = 9
    DELIVERY_PREVIEW_CHARS = 200
    DELIVERY_LIST_MAX = 500
    DELIVERY_THREAD_PREFIX = "t-"
    DELIVERY_LAUNCH_PREFIX = "l-"
    DELIVERY_SKILLS_MAX = 50
    DELIVERY_ROLE_MAX_CHARS = 300

    def __init__(self, resources: ResourceStore, events: EventLog, roster: TeamRoster) -> None:
        self._resources = resources
        self._events = events
        self._roster = roster

    def create(
        self,
        sender: ResourceRef,
        agent_id: str,
        text: str,
        kind: str = Delivery.KIND_PROMPT,
        map_options: dict[str, object] | None = None,
    ) -> Delivery:
        """Hold something for an agent and log that it was sent.

        Args:
            sender: the person or agent sending it
            agent_id: the agent it is for
            text: what to tell the agent, for a prompt
            kind: `prompt`, `interrupt` or `approve`
            map_options: for `approve`, the `choice`: `once` or `deny`; for `prompt`, the `thread` it
                answers, and `no_reply` when the sender wants no answer

        Returns:
            the delivery, pending, or held when the sender went past its team's limits

        Raises:
            ValidationError: if the kind, the text or the options are unusable, the agent has ended or runs
                under no rook, or an agent sends to one it shares no team with
            NotFoundError: if there is no such agent
        """
        map_options = dict(map_options or {})
        if kind not in Delivery.SET_AGENT_KINDS:
            raise ValidationError(f"an agent takes a prompt, an interrupt or an approval, not {kind!r}")
        if kind == Delivery.KIND_PROMPT:
            self._check_text(text)
        elif kind == Delivery.KIND_APPROVE and map_options.get("choice") not in Delivery.SET_APPROVE_CHOICES:
            raise ValidationError("an approval needs a choice: once or deny")
        agent_ref = ResourceRef.of(ResourceKinds.AGENT.name, agent_id)
        agent = self._resources.get(agent_ref)
        if agent.map_attributes.get("closed_at"):
            raise ValidationError(f"agent {agent.name} has ended")
        rook_name = self._rook_of(agent)
        if not rook_name:
            raise ValidationError(f"agent {agent.name} runs under no rook, so nothing can reach it")
        held_reason = ""
        if kind == Delivery.KIND_PROMPT:
            list_teams = self._teams_between(sender, agent_ref.id)
            map_options = self._prompt_options(map_options, sender, None)
            held_reason = self._held_reason(sender, str(map_options["thread"]), int(map_options["hop"]), list_teams)
        return self._hold(
            sender=sender,
            agent_id=agent_ref.id,
            rook_name=rook_name,
            text=text if kind == Delivery.KIND_PROMPT else "",
            kind=kind,
            map_options=map_options,
            held_reason=held_reason,
        )

    def create_broadcast(
        self,
        sender: ResourceRef,
        team_id: str,
        text: str,
        map_options: dict[str, object] | None = None,
    ) -> list[Delivery]:
        """Hold one message for every member of a team but its sender, all in one thread.

        Args:
            sender: the person, or the member agent, sending it
            team_id: the team
            text: what to tell them
            map_options: the `thread` it answers, and `no_reply` when the sender wants no answer

        Returns:
            one delivery per member reachable now, each pending, or held when the sender went past the
            team's limits

        Raises:
            ValidationError: if the text is unusable, an agent sends to a team it is not in, or no member
                can be reached
            NotFoundError: if there is no such team
        """
        self._check_text(text)
        team = self._resources.get(ResourceRef.of(ResourceKinds.TEAM.name, team_id))
        map_members = TeamRoster.members_of(team)
        if self._is_bound_agent(sender) and sender.id.split("~")[0] not in map_members:
            raise ValidationError(f"agent {sender.id} is not in team {team.name}")
        map_options = self._prompt_options(dict(map_options or {}), sender, team.id)
        map_options["batch"] = "b-" + secrets.token_urlsafe(self.DELIVERY_ID_BYTES)
        held_reason = self._held_reason(sender, str(map_options["thread"]), int(map_options["hop"]), [team])
        list_deliveries: list[Delivery] = []
        for agent_id in map_members:
            if agent_id == sender.id.split("~")[0]:
                continue
            agent_ref = ResourceRef(kind=ResourceKinds.AGENT.name, id=agent_id)
            if not self._resources.exists(agent_ref):
                continue
            agent = self._resources.get(agent_ref)
            rook_name = self._rook_of(agent)
            if agent.map_attributes.get("closed_at") or not rook_name:
                continue
            list_deliveries.append(self._hold(
                sender=sender,
                agent_id=agent_id,
                rook_name=rook_name,
                text=text,
                kind=Delivery.KIND_PROMPT,
                map_options=dict(map_options),
                held_reason=held_reason,
            ))
        if not list_deliveries:
            raise ValidationError(f"no other member of team {team.name} can be reached now")
        return list_deliveries

    def release(self, delivery_id: str) -> Delivery:
        """Let a held delivery go on its way, as the user decided; its thread may then go as far again.

        Raises:
            ValidationError: if the delivery is not held
            NotFoundError: if there is no such delivery
        """
        delivery = self._decide_held(delivery_id, Delivery.STATUS_PENDING)
        self._events.record([{
            "actor": EventLog.EVENT_PERSON.as_payload(),
            "verb": EventVerbs.MESSAGED,
            "object": delivery.target().as_payload(),
            "detail": {"delivery": delivery.id, "kind": delivery.kind, "released": True},
        }])
        return delivery

    def cancel(self, delivery_id: str) -> Delivery:
        """Drop a held delivery, as the user decided.

        Raises:
            ValidationError: if the delivery is not held
            NotFoundError: if there is no such delivery
        """
        delivery = self._decide_held(delivery_id, Delivery.STATUS_CANCELLED)
        self._events.record([{
            "actor": EventLog.EVENT_PERSON.as_payload(),
            "verb": EventVerbs.UNDELIVERED,
            "object": delivery.target().as_payload(),
            "detail": {"delivery": delivery.id, "reason": "cancelled by the user"},
        }])
        return delivery

    def launch(self, launch_id: str) -> Delivery:
        """The spawn that asked for a launch.

        Raises:
            NotFoundError: if no spawn names that launch
        """
        with self._resources.database.reading() as connection:
            row = connection.execute(
                "SELECT * FROM deliveries WHERE kind = ? AND json_extract(options, '$.launch') = ?",
                (Delivery.KIND_SPAWN, launch_id),
            ).fetchone()
        if row is None:
            raise NotFoundError(f"no such launch: {launch_id}")
        return self._delivery_of(row)

    def bind_launches(self, list_events: list[Event]) -> None:
        """Give each agent a launch started its identity and teams, as the launch asked; the agent names its
        launch as it starts."""
        for event in list_events:
            launch_id = str(event.map_detail.get("launch") or "")
            if event.verb != EventVerbs.STARTED or event.actor.kind != ResourceKinds.AGENT.name or not launch_id:
                continue
            try:
                spawn = self.launch(launch_id)
            except NotFoundError:
                continue
            self._apply_launch(event.actor.id, spawn.map_options)

    def _apply_launch(self, agent_id: str, map_launch: dict[str, object]) -> None:
        agent_ref = ResourceRef(kind=ResourceKinds.AGENT.name, id=agent_id)
        role = str(map_launch.get("role") or "")
        if role:
            with self._resources.database.transaction() as connection:
                agent = self._resources.get(agent_ref)
                is_new_role = not agent.map_attributes.get("role")
                if is_new_role:
                    agent.map_attributes["role"] = role
                    agent.map_attributes["role_source"] = "launch"
                    self._resources.put(agent, connection)
            if is_new_role:
                self._events.record_change(None, EventVerbs.UPDATED, agent_ref)
        list_teams = map_launch.get("teams")
        for map_team in list_teams if isinstance(list_teams, list) else []:
            team_ref = ResourceRef(kind=ResourceKinds.TEAM.name, id=str(map_team.get("team") or ""))
            if (
                not self._resources.exists(team_ref)
                or agent_id in TeamRoster.members_of(self._resources.get(team_ref))
            ):
                continue
            self._roster.join(team_ref.id, agent_id, str(map_team.get("duty") or ""), None)

    def _decide_held(self, delivery_id: str, status: str) -> Delivery:
        delivery = self.get(delivery_id)
        if delivery.status != Delivery.STATUS_HELD:
            raise ValidationError(f"delivery {delivery_id} is not held")
        delivery.status = status
        delivery.updated_at = ResourceStore.now_timestamp()
        if status == Delivery.STATUS_PENDING:
            delivery.map_options["released"] = True
        with self._resources.database.transaction() as connection:
            connection.execute(
                "UPDATE deliveries SET status = ?, options = ?, updated_at = ? WHERE id = ?",
                (status, json.dumps(delivery.map_options), delivery.updated_at, delivery_id),
            )
        return delivery

    @staticmethod
    def _is_bound_agent(sender: ResourceRef) -> bool:
        """Whether the sender is an agent, held to its teams, rather than a person; Rookery's own agents
        are held as any other, so Raven messages only the teams the user put it in."""
        return sender.kind == ResourceKinds.AGENT.name

    def _teams_between(self, sender: ResourceRef, agent_id: str) -> list[Resource]:
        if not self._is_bound_agent(sender):
            return []
        list_teams = self._roster.shared_teams(sender.id.split("~")[0], agent_id)
        if not list_teams:
            raise ValidationError(
                f"agent {sender.id} shares no team with {agent_id}; an agent messages only its teammates",
            )
        return list_teams

    def _prompt_options(
        self,
        map_options: dict[str, object],
        sender: ResourceRef,
        team_id: str | None,
    ) -> dict[str, object]:
        thread = str(map_options.get("thread") or "")
        if thread and not ResourceRef.REF_ID_PATTERN.match(thread):
            raise ValidationError(f"unusable thread: {thread!r}")
        if not thread:
            thread = self.DELIVERY_THREAD_PREFIX + secrets.token_urlsafe(self.DELIVERY_ID_BYTES)
        map_prompt: dict[str, object] = {"thread": thread, "hop": self._thread_hops(thread) + 1}
        if map_options.get("no_reply"):
            map_prompt["no_reply"] = True
        if team_id:
            map_prompt["team"] = team_id
        sender_ref = ResourceRef(kind=ResourceKinds.AGENT.name, id=sender.id.split("~")[0])
        if sender.kind == ResourceKinds.AGENT.name and self._resources.exists(sender_ref):
            sender_agent = self._resources.get(sender_ref)
            map_prompt["sender_title"] = str(sender_agent.map_attributes.get("title") or sender_agent.name)
        return map_prompt

    def _thread_hops(self, thread: str) -> int:
        with self._resources.database.reading() as connection:
            row = connection.execute(
                """
                SELECT COUNT(DISTINCT COALESCE(json_extract(options, '$.batch'), id)) AS hops
                FROM deliveries WHERE json_extract(options, '$.thread') = ?
                """,
                (thread,),
            ).fetchone()
        return int(row["hops"] or 0)

    def _held_reason(self, sender: ResourceRef, thread: str, hop: int, list_teams: list[Resource]) -> str:
        """Why a prompt from an agent is held for the user, or empty when it may go."""
        if not self._is_bound_agent(sender):
            return ""
        limits = TeamLimits.loosest(list_teams)
        with self._resources.database.reading() as connection:
            row = connection.execute(
                """
                SELECT MAX(json_extract(options, '$.hop')) AS hop FROM deliveries
                WHERE json_extract(options, '$.thread') = ? AND json_extract(options, '$.released') = 1
                """,
                (thread,),
            ).fetchone()
            released_hop = int(row["hop"] or 0)
            since = (
                datetime.fromisoformat(ResourceStore.now_timestamp()) - timedelta(minutes=limits.window_minutes)
            ).isoformat(timespec="milliseconds")
            row = connection.execute(
                """
                SELECT COUNT(DISTINCT COALESCE(json_extract(options, '$.batch'), id)) AS sends FROM deliveries
                WHERE sender_kind = ? AND sender_id = ? AND kind = ? AND created_at >= ? AND status != ?
                """,
                (sender.kind, sender.id, Delivery.KIND_PROMPT, since, Delivery.STATUS_CANCELLED),
            ).fetchone()
            sends = int(row["sends"] or 0)
        if hop - released_hop > limits.thread_hops:
            return f"the thread went past {limits.thread_hops} messages"
        if sends >= limits.sends_per_window:
            return f"the sender sent {sends} messages in {limits.window_minutes} minutes"
        return ""

    def create_spawn(self, sender: ResourceRef, rook_name: str, prompt: str, map_options: dict[str, object]) -> Delivery:
        """Hold a new session for a rook to start, and log that it was asked for.

        Args:
            sender: the person or agent asking
            rook_name: the rook to start it on
            prompt: the session's first prompt, or empty for none
            map_options: the `cwd` to start in, an absolute path on the rook, and the `harness`; optionally
                the `launch` id the session names as it starts, else one is made; the `playbook` to install
                and further `skills`; the `role` it takes; and the `teams` it joins, each a `team` and a
                `duty`

        Returns:
            the delivery, pending, its options carrying the launch id

        Raises:
            ValidationError: if the directory, the harness, the launch or the prompt is unusable
            NotFoundError: if there is no such rook, playbook, skill or team
        """
        cwd = str(map_options.get("cwd") or "")
        harness = str(map_options.get("harness") or "claude")
        if not cwd.startswith("/"):
            raise ValidationError("a new session needs an absolute directory on its rook")
        if harness not in Delivery.SET_SPAWN_HARNESSES:
            raise ValidationError(f"a rook starts claude or codex, not {harness!r}")
        if prompt:
            self._check_text(prompt)
        self._resources.get(ResourceRef.of(ResourceKinds.ROOK.name, rook_name))
        return self._hold(
            sender=sender,
            agent_id="",
            rook_name=rook_name,
            text=prompt,
            kind=Delivery.KIND_SPAWN,
            map_options={"cwd": cwd, "harness": harness, **self._launch_options(map_options)},
        )

    def _launch_options(self, map_options: dict[str, object]) -> dict[str, object]:
        launch_id = str(map_options.get("launch") or "")
        if launch_id and not ResourceRef.REF_ID_PATTERN.match(launch_id):
            raise ValidationError(f"unusable launch id: {launch_id!r}")
        map_launch: dict[str, object] = {
            "launch": launch_id or self.DELIVERY_LAUNCH_PREFIX + secrets.token_urlsafe(self.DELIVERY_ID_BYTES),
        }
        playbook_id = str(map_options.get("playbook") or "")
        if playbook_id:
            map_launch["playbook"] = self._resources.get(ResourceRef.of(ResourceKinds.PLAYBOOK.name, playbook_id)).id
        list_skills = map_options.get("skills") or []
        if not isinstance(list_skills, list) or len(list_skills) > self.DELIVERY_SKILLS_MAX:
            raise ValidationError(f"skills is a list of at most {self.DELIVERY_SKILLS_MAX} skill ids")
        if list_skills:
            map_launch["skills"] = [
                self._resources.get(ResourceRef.of(ResourceKinds.SKILL.name, str(skill_id))).id
                for skill_id in list_skills
            ]
        role = str(map_options.get("role") or "").strip()
        if len(role) > self.DELIVERY_ROLE_MAX_CHARS:
            raise ValidationError(f"a role is at most {self.DELIVERY_ROLE_MAX_CHARS} characters")
        if role:
            map_launch["role"] = role
        list_teams = map_options.get("teams") or []
        if not isinstance(list_teams, list):
            raise ValidationError("teams is a list of {team, duty}")
        list_joins: list[dict[str, object]] = []
        for map_team in list_teams:
            if not isinstance(map_team, dict):
                raise ValidationError("teams is a list of {team, duty}")
            team = self._resources.get(ResourceRef.of(ResourceKinds.TEAM.name, str(map_team.get("team") or "")))
            list_joins.append({"team": team.id, "duty": str(map_team.get("duty") or "").strip()})
        if list_joins:
            map_launch["teams"] = list_joins
        return map_launch

    def _check_text(self, text: str) -> None:
        if not text.strip():
            raise ValidationError("a message needs text")
        if len(text.encode("utf-8")) > self.DELIVERY_TEXT_MAX_BYTES:
            raise ValidationError(f"a message is at most {self.DELIVERY_TEXT_MAX_BYTES} bytes")

    def _hold(
        self,
        sender: ResourceRef,
        agent_id: str,
        rook_name: str,
        text: str,
        kind: str,
        map_options: dict[str, object],
        held_reason: str = "",
    ) -> Delivery:
        at = ResourceStore.now_timestamp()
        delivery = Delivery(
            id="d-" + secrets.token_urlsafe(self.DELIVERY_ID_BYTES),
            agent_id=agent_id,
            rook_name=rook_name,
            text=text,
            sender=sender,
            status=Delivery.STATUS_HELD if held_reason else Delivery.STATUS_PENDING,
            map_detail={"reason": held_reason} if held_reason else {},
            created_at=at,
            updated_at=at,
            kind=kind,
            map_options=map_options,
        )
        with self._resources.database.transaction() as connection:
            connection.execute(
                """
                INSERT INTO deliveries
                    (id, agent_id, rook_name, text, sender_kind, sender_id, status, detail, created_at, updated_at,
                     kind, options)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    delivery.id,
                    delivery.agent_id,
                    delivery.rook_name,
                    delivery.text,
                    sender.kind,
                    sender.id,
                    delivery.status,
                    json.dumps(delivery.map_detail),
                    at,
                    at,
                    kind,
                    json.dumps(map_options),
                ),
            )
        self._events.record([{
            "actor": sender.as_payload(),
            "verb": EventVerbs.MESSAGED,
            "at": at,
            "object": delivery.target().as_payload(),
            "detail": self._event_detail(delivery, held_reason),
        }])
        return delivery

    def _event_detail(self, delivery: Delivery, held_reason: str) -> dict[str, object]:
        map_detail: dict[str, object] = {
            "delivery": delivery.id,
            "kind": delivery.kind,
            "preview": delivery.text[: self.DELIVERY_PREVIEW_CHARS],
        }
        for key in ("thread", "hop", "team", "no_reply", "launch"):
            if key in delivery.map_options:
                map_detail[key] = delivery.map_options[key]
        if held_reason:
            map_detail["held"] = held_reason
        return map_detail

    def get(self, delivery_id: str) -> Delivery:
        """Look up one delivery.

        Raises:
            NotFoundError: if there is no such delivery
        """
        with self._resources.database.reading() as connection:
            row = connection.execute("SELECT * FROM deliveries WHERE id = ?", (delivery_id,)).fetchone()
        if row is None:
            raise NotFoundError(f"no such delivery: {delivery_id}")
        return self._delivery_of(row)

    def open_for_rook(self, rook_name: str) -> list[Delivery]:
        """The deliveries a rook has yet to finish, oldest first, after expiring the stale ones.

        Args:
            rook_name: the rook

        Returns:
            the deliveries pending, sent or waiting
        """
        self._expire()
        with self._resources.database.reading() as connection:
            list_rows = connection.execute(
                """
                SELECT * FROM deliveries
                WHERE rook_name = ? AND status IN (?, ?, ?)
                ORDER BY created_at
                """,
                (rook_name, *sorted(Delivery.SET_OPEN_STATUSES)),
            ).fetchall()
        return [self._delivery_of(row) for row in list_rows]

    def report_for_rookery(self, delivery_id: str, status: str, reason: str) -> Delivery:
        """Record what Rookery did with a message for one of its own agents, which it reads over HTTP rather
        than through a link.

        Args:
            delivery_id: the delivery
            status: `waiting`, `delivered` or `failed`
            reason: why, or how it was delivered

        Returns:
            the delivery as updated

        Raises:
            ValidationError: if the status is not one a rook reports
            NotFoundError: if there is no such delivery for Rookery's own agents
        """
        return self.report(TeamRoster.ROSTER_ROOKERY_ROOK, delivery_id, status, reason)

    def list_recent(self, agent_id: str | None, limit: int, sender_id: str | None = None) -> list[Delivery]:
        """The latest deliveries, newest first.

        Args:
            agent_id: only those for this agent, or None for all
            limit: the greatest number to return
            sender_id: only those this agent sent, or None for all

        Returns:
            the deliveries
        """
        list_conditions = ["1 = 1"]
        list_params: list[object] = []
        if agent_id:
            list_conditions.append("agent_id = ?")
            list_params.append(agent_id)
        if sender_id:
            list_conditions.append("sender_kind = ? AND sender_id = ?")
            list_params.extend([ResourceKinds.AGENT.name, sender_id])
        list_params.append(max(1, min(limit, self.DELIVERY_LIST_MAX)))
        with self._resources.database.reading() as connection:
            list_rows = connection.execute(
                f"SELECT * FROM deliveries WHERE {' AND '.join(list_conditions)} ORDER BY created_at DESC LIMIT ?",
                list_params,
            ).fetchall()
        return [self._delivery_of(row) for row in list_rows]

    def mark_sent(self, delivery_id: str) -> None:
        """Note that a delivery was handed to its rook, unless it already went further."""
        with self._resources.database.transaction() as connection:
            connection.execute(
                "UPDATE deliveries SET status = ?, updated_at = ? WHERE id = ? AND status = ?",
                (Delivery.STATUS_SENT, ResourceStore.now_timestamp(), delivery_id, Delivery.STATUS_PENDING),
            )

    def report(self, rook_name: str, delivery_id: str, status: str, reason: str) -> Delivery:
        """Record what a rook did with a delivery, logging it once it reached the agent or could not.

        Args:
            rook_name: the rook reporting, which must be the one the delivery was routed to
            delivery_id: the delivery
            status: `waiting`, `delivered` or `failed`
            reason: why it is waiting or failed, or how it was delivered

        Returns:
            the delivery as updated

        Raises:
            ValidationError: if the status is not one a rook reports
            NotFoundError: if the rook has no such delivery
        """
        if status not in Delivery.SET_REPORTED_STATUSES:
            raise ValidationError(f"a rook reports a delivery as waiting, delivered or failed, not {status!r}")
        delivery = self.get(delivery_id)
        if delivery.rook_name != rook_name:
            raise NotFoundError(f"no such delivery: {delivery_id}")
        if not delivery.is_open():
            return delivery
        at = ResourceStore.now_timestamp()
        delivery.status = status
        delivery.map_detail = {"reason": reason} if reason else {}
        delivery.updated_at = at
        with self._resources.database.transaction() as connection:
            connection.execute(
                "UPDATE deliveries SET status = ?, detail = ?, updated_at = ? WHERE id = ?",
                (status, json.dumps(delivery.map_detail), at, delivery_id),
            )
        if status != Delivery.STATUS_WAITING:
            self._events.record([{
                "actor": ResourceRef.of(ResourceKinds.ROOK.name, rook_name).as_payload(),
                "verb": EventVerbs.DELIVERED if status == Delivery.STATUS_DELIVERED else EventVerbs.UNDELIVERED,
                "at": at,
                "object": delivery.target().as_payload(),
                "detail": {"delivery": delivery_id, "reason": reason},
            }])
        return delivery

    def _rook_of(self, agent: Resource) -> str:
        rook_name = str(agent.map_attributes.get("rook_name") or "")
        parent_id = str(agent.map_attributes.get("parent") or "")
        if rook_name or not parent_id:
            return rook_name
        parent_ref = ResourceRef.of(ResourceKinds.AGENT.name, parent_id)
        if not self._resources.exists(parent_ref):
            return ""
        return str(self._resources.get(parent_ref).map_attributes.get("rook_name") or "")

    def _expire(self) -> None:
        cutoff = (datetime.fromisoformat(ResourceStore.now_timestamp()) - self.DELIVERY_TTL).isoformat(
            timespec="milliseconds",
        )
        with self._resources.database.transaction() as connection:
            connection.execute(
                "UPDATE deliveries SET status = ? WHERE created_at < ? AND status IN (?, ?, ?, ?)",
                (Delivery.STATUS_EXPIRED, cutoff, *sorted(Delivery.SET_OPEN_STATUSES), Delivery.STATUS_HELD),
            )

    @staticmethod
    def _delivery_of(row: sqlite3.Row) -> Delivery:
        return Delivery(
            id=row["id"],
            agent_id=row["agent_id"],
            rook_name=row["rook_name"],
            text=row["text"],
            sender=ResourceRef(kind=row["sender_kind"], id=row["sender_id"]),
            status=row["status"],
            map_detail=json.loads(row["detail"]),
            created_at=row["created_at"],
            updated_at=row["updated_at"],
            kind=row["kind"],
            map_options=json.loads(row["options"]),
        )
