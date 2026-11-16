import json
import sqlite3
import threading
from dataclasses import dataclass, field
from rookd.errors import ValidationError
from rookd.records import RecordStore
from rookd.resources import Resource, ResourceKinds, ResourceRef, ResourceStore


class AgentStates:
    """The states an agent session can be in, the same for every harness; the desktop draws one crow
    animation for each."""

    IDLE = "idle"
    THINKING = "thinking"
    WORKING = "working"
    NEEDS_APPROVAL = "needs_approval"
    NEEDS_INPUT = "needs_input"
    COMPACTING = "compacting"
    DONE = "done"
    ERROR = "error"
    RATE_LIMITED = "rate_limited"
    ENDED = "ended"
    SET_STATES = frozenset({
        IDLE,
        THINKING,
        WORKING,
        NEEDS_APPROVAL,
        NEEDS_INPUT,
        COMPACTING,
        DONE,
        ERROR,
        RATE_LIMITED,
        ENDED,
    })


class EventVerbs:
    """What an event says happened. The relation verbs also draw an edge from the actor to the object."""

    STARTED = "started"
    STATE = "state"
    ENDED = "ended"
    CREATED = "created"
    UPDATED = "updated"
    DELETED = "deleted"
    USES = "uses"
    MOUNTS = "mounts"
    FOLLOWS = "follows"
    SPAWNED = "spawned"
    WROTE = "wrote"
    DEPENDS_ON = "depends_on"
    MESSAGED = "messaged"
    CONNECTED = "connected"
    DISCONNECTED = "disconnected"
    DELIVERED = "delivered"
    UNDELIVERED = "undelivered"
    SET_RELATION_VERBS = frozenset({
        CREATED,
        UPDATED,
        USES,
        MOUNTS,
        FOLLOWS,
        SPAWNED,
        WROTE,
        DEPENDS_ON,
        MESSAGED,
    })
    SET_VERBS = SET_RELATION_VERBS | {
        STARTED,
        STATE,
        ENDED,
        DELETED,
        CONNECTED,
        DISCONNECTED,
        DELIVERED,
        UNDELIVERED,
    }


@dataclass
class Event:
    """One thing that happened to the managed resources, in the order the server recorded it."""

    seq: int
    at: str
    actor: ResourceRef
    verb: str
    object: ResourceRef | None = None
    map_detail: dict[str, object] = field(default_factory=dict)

    def as_payload(self) -> dict[str, object]:
        """Render the event as JSON.

        Returns:
            a mapping of the sequence number, the time, who did what to what, and the details
        """
        return {
            "seq": self.seq,
            "at": self.at,
            "actor": self.actor.as_payload(),
            "verb": self.verb,
            "object": self.object.as_payload() if self.object else None,
            "detail": self.map_detail,
        }


class EventLog:
    """The append-only log of everything that happens to the managed resources. Recording an event also
    applies it: an agent's state and details, the relation it draws, and when each resource was last used.
    Readers resume from the last sequence number they saw, and can wait for the next events."""

    EVENT_PERSON = ResourceRef(kind="person", id="user")
    EVENT_REPORTS_MAX = 500
    EVENT_PAGE_MAX = 1000
    EVENT_AGENT_DETAIL_FIELDS = (
        "harness",
        "rook_name",
        "tab",
        "machine",
        "cwd",
        "git_branch",
        "account",
        "transcript_path",
        "model",
    )
    EVENT_OBJECT_ATTRIBUTE_FIELDS = ("path", "project", "text", "scope", "description")

    def __init__(self, resources: ResourceStore) -> None:
        self._resources = resources
        self._condition = threading.Condition()
        self._last_seq = self._read_last_seq()

    def record(self, list_reports: list[object]) -> list[Event]:
        """Apply and log a batch of reported events, all or none of them.

        Args:
            list_reports: the decoded events, each a mapping with `actor`, `verb`, and optionally `at`,
                `object` and `detail`; an object may name a resource by `kind` and `name` instead of `id`,
                and is created if it is not managed yet

        Returns:
            the events as logged, with their sequence numbers

        Raises:
            ValidationError: if the batch or any event in it is unusable
        """
        if len(list_reports) > self.EVENT_REPORTS_MAX:
            raise ValidationError(f"at most {self.EVENT_REPORTS_MAX} events go in one batch")
        list_events: list[Event] = []
        with self._resources.database.transaction() as connection:
            for report in list_reports:
                list_events.append(self._record_one(report, connection))
        if list_events:
            with self._condition:
                self._last_seq = list_events[-1].seq
                self._condition.notify_all()
        return list_events

    def after(self, seq: int, limit: int = EVENT_PAGE_MAX) -> list[Event]:
        """Read the events logged after a sequence number, oldest first.

        Args:
            seq: the last sequence number the reader has, 0 for the start
            limit: the greatest number of events to return

        Returns:
            the events
        """
        with self._resources.database.reading() as connection:
            list_rows = connection.execute(
                "SELECT * FROM events WHERE seq > ? ORDER BY seq LIMIT ?",
                (seq, min(limit, self.EVENT_PAGE_MAX)),
            ).fetchall()
        return [self._event_of(row) for row in list_rows]

    def latest(self, limit: int) -> list[Event]:
        """Read the most recent events, oldest first.

        Args:
            limit: how many

        Returns:
            the events
        """
        with self._resources.database.reading() as connection:
            list_rows = connection.execute(
                "SELECT * FROM (SELECT * FROM events ORDER BY seq DESC LIMIT ?) ORDER BY seq",
                (min(limit, self.EVENT_PAGE_MAX),),
            ).fetchall()
        return [self._event_of(row) for row in list_rows]

    def wait_after(self, seq: int, timeout_seconds: float) -> list[Event]:
        """Wait until events are logged after a sequence number, or the time runs out.

        Args:
            seq: the last sequence number the reader has
            timeout_seconds: how long to wait for one

        Returns:
            the new events, or none when the time ran out first
        """
        with self._condition:
            self._condition.wait_for(lambda: self._last_seq > seq, timeout=timeout_seconds)
        return self.after(seq)

    def wake(self) -> None:
        """Release every reader waiting for events, as the server stops."""
        with self._condition:
            self._condition.notify_all()

    def record_change(self, actor: ResourceRef | None, verb: str, target: ResourceRef) -> Event:
        """Log a change made through the resource API, by an agent or by a person.

        Args:
            actor: the agent that made it, or None for a person
            verb: `created`, `updated` or `deleted`
            target: the resource changed

        Returns:
            the event as logged
        """
        report: dict[str, object] = {
            "actor": (actor or self.EVENT_PERSON).as_payload(),
            "verb": verb,
            "object": target.as_payload(),
        }
        return self.record([report])[0]

    def _record_one(self, report: object, connection: sqlite3.Connection) -> Event:
        if not isinstance(report, dict):
            raise ValidationError("an event must be an object")
        at = str(report.get("at") or ResourceStore.now_timestamp())
        verb = str(report.get("verb") or "")
        if verb not in EventVerbs.SET_VERBS:
            raise ValidationError(f"unknown event verb: {verb!r}")
        actor = self._actor_of(report.get("actor"))
        map_detail = report.get("detail") if isinstance(report.get("detail"), dict) else {}
        target = self._object_of(report.get("object"), actor, map_detail, at, connection)
        if verb in EventVerbs.SET_RELATION_VERBS and target is None:
            raise ValidationError(f"a {verb} event needs an object")
        if actor.kind == ResourceKinds.AGENT.name:
            self._apply_to_agent(actor, verb, map_detail, at, connection)
        if actor.kind == ResourceKinds.ROOK.name and verb in (EventVerbs.CONNECTED, EventVerbs.DISCONNECTED):
            self._apply_to_rook(actor, verb, map_detail, at, connection)
        if target is not None and verb in EventVerbs.SET_RELATION_VERBS and actor != self.EVENT_PERSON:
            self._resources.relate(actor, verb, target, at, connection)
        if target is not None and verb != EventVerbs.DELETED:
            self._resources.touch(target, at, connection)
        cursor = connection.execute(
            """
            INSERT INTO events (at, actor_kind, actor_id, verb, object_kind, object_id, detail)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                at,
                actor.kind,
                actor.id,
                verb,
                target.kind if target else None,
                target.id if target else None,
                json.dumps(map_detail),
            ),
        )
        return Event(
            seq=int(cursor.lastrowid or 0),
            at=at,
            actor=actor,
            verb=verb,
            object=target,
            map_detail=map_detail,
        )

    def _actor_of(self, map_actor: object) -> ResourceRef:
        if isinstance(map_actor, dict) and map_actor.get("kind") == self.EVENT_PERSON.kind:
            return self.EVENT_PERSON
        return ResourceRef.from_payload(map_actor)

    def _apply_to_rook(
        self,
        actor: ResourceRef,
        verb: str,
        map_detail: dict[str, object],
        at: str,
        connection: sqlite3.Connection,
    ) -> None:
        if self._resources.exists(actor):
            rook = self._resources.get(actor)
        else:
            rook = Resource(kind=actor.kind, id=actor.id, name=actor.id)
        rook.map_attributes["online"] = verb == EventVerbs.CONNECTED
        rook.map_attributes["connected_at" if verb == EventVerbs.CONNECTED else "disconnected_at"] = at
        for key in ("machine", "accepts_prompts"):
            if key in map_detail:
                rook.map_attributes[key] = map_detail[key]
        self._resources.put(rook, connection)

    def _apply_to_agent(
        self,
        actor: ResourceRef,
        verb: str,
        map_detail: dict[str, object],
        at: str,
        connection: sqlite3.Connection,
    ) -> None:
        """Bring an agent's record up to date with what it reported, creating it if this is its first word."""
        agent = self._stored(actor, connection) or Resource(
            kind=actor.kind,
            id=actor.id,
            name=actor.id,
            map_attributes={"state": AgentStates.IDLE, "opened_at": at, "closed_at": None},
        )
        if verb == EventVerbs.STARTED:
            for name in self.EVENT_AGENT_DETAIL_FIELDS:
                if name in map_detail:
                    agent.map_attributes[name] = map_detail[name]
            agent.name = str(map_detail.get("name") or agent.name)
            agent.map_attributes["state"] = AgentStates.IDLE
            agent.map_attributes["closed_at"] = None
            parent_id = map_detail.get("parent")
            if parent_id:
                parent = ResourceRef.of(ResourceKinds.AGENT.name, str(parent_id))
                agent.map_attributes["parent"] = parent.id
                agent.origin = parent
                if self._stored(parent, connection) is not None:
                    self._resources.relate(parent, EventVerbs.SPAWNED, actor, at, connection)
        elif verb == EventVerbs.STATE:
            state = str(map_detail.get("state") or "")
            if state not in AgentStates.SET_STATES:
                raise ValidationError(f"unknown agent state: {state!r}")
            agent.map_attributes["state"] = state
            if state == AgentStates.ENDED:
                agent.map_attributes["closed_at"] = at
        elif verb == EventVerbs.ENDED:
            agent.map_attributes["state"] = AgentStates.ENDED
            agent.map_attributes["closed_at"] = at
        agent.last_used_at = max(agent.last_used_at, at)
        self._resources.put(agent, connection)

    def _object_of(
        self,
        map_object: object,
        actor: ResourceRef,
        map_detail: dict[str, object],
        at: str,
        connection: sqlite3.Connection,
    ) -> ResourceRef | None:
        """The resource an event acts on, found by id or by name, and created if it is not managed yet."""
        if map_object is None:
            return None
        if not isinstance(map_object, dict):
            raise ValidationError("an event's object must be an object with a kind and an id or a name")
        kind = ResourceKinds.get(str(map_object.get("kind") or "")).name
        name = str(map_object.get("name") or "").strip()
        resource_id = str(map_object.get("id") or "").strip()
        if not resource_id:
            if not name:
                raise ValidationError("an event's object needs an id or a name")
            resource_id = self._id_by_name(kind, name, connection) or RecordStore.slugify(name, fallback=kind)
        target = ResourceRef.of(kind, resource_id)
        stored = self._stored(target, connection)
        map_found = {
            key: map_detail[key]
            for key in self.EVENT_OBJECT_ATTRIBUTE_FIELDS
            if key in map_detail and kind == ResourceKinds.MEMORY.name
        }
        if stored is None:
            self._resources.put(
                Resource(
                    kind=kind,
                    id=resource_id,
                    name=name or resource_id,
                    map_attributes={"discovered": True, **map_found},
                    origin=actor if actor != self.EVENT_PERSON else None,
                    last_used_at=at,
                ),
                connection,
            )
        elif map_found:
            stored.map_attributes.update(map_found)
            self._resources.put(stored, connection)
        return target

    def _stored(self, ref: ResourceRef, connection: sqlite3.Connection) -> Resource | None:
        row = connection.execute("SELECT * FROM resources WHERE kind = ? AND id = ?", (ref.kind, ref.id)).fetchone()
        return ResourceStore.resource_of(row) if row is not None else None

    @staticmethod
    def _id_by_name(kind: str, name: str, connection: sqlite3.Connection) -> str | None:
        row = connection.execute(
            "SELECT id FROM resources WHERE kind = ? AND name = ? ORDER BY last_used_at DESC LIMIT 1",
            (kind, name),
        ).fetchone()
        return str(row["id"]) if row is not None else None

    def _read_last_seq(self) -> int:
        with self._resources.database.reading() as connection:
            row = connection.execute("SELECT MAX(seq) AS last FROM events").fetchone()
        return int(row["last"] or 0)

    @staticmethod
    def _event_of(row: sqlite3.Row) -> Event:
        target = None
        if row["object_kind"] and row["object_id"]:
            target = ResourceRef(kind=row["object_kind"], id=row["object_id"])
        return Event(
            seq=row["seq"],
            at=row["at"],
            actor=ResourceRef(kind=row["actor_kind"], id=row["actor_id"]),
            verb=row["verb"],
            object=target,
            map_detail=json.loads(row["detail"]),
        )
