import json
import secrets
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from rookd.errors import NotFoundError, ValidationError
from rookd.events import EventLog, EventVerbs
from rookd.resources import Resource, ResourceKinds, ResourceRef, ResourceStore


@dataclass
class Delivery:
    """Text on its way to an agent: a prompt from a person, or a message from another agent."""

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
        }


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

    def create(self, sender: ResourceRef, agent_id: str, text: str) -> Delivery:
        """Hold text for an agent and log that it was sent.

        Args:
            sender: the person or agent sending it
            agent_id: the agent it is for
            text: what to tell the agent

        Returns:
            the delivery, pending

        Raises:
            ValidationError: if the text is empty or too long, or the agent has ended or runs under no rook
            NotFoundError: if there is no such agent
        """
        if not text.strip():
            raise ValidationError("a message needs text")
        if len(text.encode("utf-8")) > self.DELIVERY_TEXT_MAX_BYTES:
            raise ValidationError(f"a message is at most {self.DELIVERY_TEXT_MAX_BYTES} bytes")
        agent_ref = ResourceRef.of(ResourceKinds.AGENT.name, agent_id)
        agent = self._resources.get(agent_ref)
        if agent.map_attributes.get("closed_at"):
            raise ValidationError(f"agent {agent.name} has ended")
        rook_name = self._rook_of(agent)
        if not rook_name:
            raise ValidationError(f"agent {agent.name} runs under no rook, so nothing can reach it")
        at = ResourceStore.now_timestamp()
        delivery = Delivery(
            id="d-" + secrets.token_urlsafe(self.DELIVERY_ID_BYTES),
            agent_id=agent_ref.id,
            rook_name=rook_name,
            text=text,
            sender=sender,
            status=Delivery.STATUS_PENDING,
            created_at=at,
            updated_at=at,
        )
        with self._resources.database.transaction() as connection:
            connection.execute(
                """
                INSERT INTO deliveries
                    (id, agent_id, rook_name, text, sender_kind, sender_id, status, detail, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                ),
            )
        self._events.record([{
            "actor": sender.as_payload(),
            "verb": EventVerbs.MESSAGED,
            "at": at,
            "object": agent_ref.as_payload(),
            "detail": {"delivery": delivery.id, "preview": text[: self.DELIVERY_PREVIEW_CHARS]},
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
                "object": ResourceRef.of(ResourceKinds.AGENT.name, delivery.agent_id).as_payload(),
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
        )
