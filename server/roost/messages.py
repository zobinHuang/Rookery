import json
import secrets
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from roost.errors import NotFoundError, ValidationError
from roost.events import EventLog, EventVerbs
from roost.resources import Resource, ResourceKinds, ResourceRef, ResourceStore


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
    each. A delivery is routed by the rook its agent runs under, which for a subagent is its parent's."""

    DELIVERY_TEXT_MAX_BYTES = 64 * 1024
    DELIVERY_TTL = timedelta(days=1)
    DELIVERY_ID_BYTES = 9
    DELIVERY_PREVIEW_CHARS = 200
    DELIVERY_LIST_MAX = 500

    def __init__(self, resources: ResourceStore, events: EventLog) -> None:
        self._resources = resources
        self._events = events

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
            map_options: for `approve`, the `choice`: `once` or `deny`

        Returns:
            the delivery, pending

        Raises:
            ValidationError: if the kind, the text or the options are unusable, or the agent has ended or
                runs under no rook
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
        return self._hold(
            sender=sender,
            agent_id=agent_ref.id,
            rook_name=rook_name,
            text=text if kind == Delivery.KIND_PROMPT else "",
            kind=kind,
            map_options=map_options,
        )

    def create_spawn(self, sender: ResourceRef, rook_name: str, prompt: str, map_options: dict[str, object]) -> Delivery:
        """Hold a new session for a rook to start, and log that it was asked for.

        Args:
            sender: the person or agent asking
            rook_name: the rook to start it on
            prompt: the session's first prompt, or empty for none
            map_options: the `cwd` to start in, an absolute path on the rook, and the `harness`

        Returns:
            the delivery, pending

        Raises:
            ValidationError: if the directory or the harness is unusable, or the prompt too long
            NotFoundError: if there is no such rook
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
            map_options={"cwd": cwd, "harness": harness},
        )

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
    ) -> Delivery:
        at = ResourceStore.now_timestamp()
        delivery = Delivery(
            id="d-" + secrets.token_urlsafe(self.DELIVERY_ID_BYTES),
            agent_id=agent_id,
            rook_name=rook_name,
            text=text,
            sender=sender,
            status=Delivery.STATUS_PENDING,
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
                    "{}",
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
            "detail": {"delivery": delivery.id, "kind": kind, "preview": text[: self.DELIVERY_PREVIEW_CHARS]},
        }])
        return delivery

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

    def list_recent(self, agent_id: str | None, limit: int) -> list[Delivery]:
        """The latest deliveries, newest first.

        Args:
            agent_id: only those for this agent, or None for all
            limit: the greatest number to return

        Returns:
            the deliveries
        """
        list_conditions = ["1 = 1"]
        list_params: list[object] = []
        if agent_id:
            list_conditions.append("agent_id = ?")
            list_params.append(agent_id)
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
                "UPDATE deliveries SET status = ? WHERE created_at < ? AND status IN (?, ?, ?)",
                (Delivery.STATUS_EXPIRED, cutoff, *sorted(Delivery.SET_OPEN_STATUSES)),
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
