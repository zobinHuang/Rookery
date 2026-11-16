import json
import re
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime, timezone
from roost.database import Database
from roost.errors import NotFoundError, ValidationError


@dataclass(frozen=True)
class ResourceKind:
    """One kind of resource the server manages, as clients discover it."""

    name: str
    title: str
    plural_title: str
    description: str

    def as_payload(self) -> dict[str, object]:
        """Render the kind as JSON.

        Returns:
            a mapping of the kind's name, its titles and its description
        """
        return {
            "name": self.name,
            "title": self.title,
            "plural_title": self.plural_title,
            "description": self.description,
        }


class ResourceKinds:
    """The kinds of resource the server manages. A new kind is one more entry here."""

    AGENT = ResourceKind(
        name="agent",
        title="Agent",
        plural_title="Agents",
        description="A code agent session running a task, or a subagent it spawned",
    )
    SKILL = ResourceKind(
        name="skill",
        title="Skill",
        plural_title="Skills",
        description="Instructions for using a tool, fetched from a git repository",
    )
    PLAYBOOK = ResourceKind(
        name="playbook",
        title="Playbook",
        plural_title="Playbooks",
        description="A standard way to solve one kind of problem, with the skills it depends on",
    )
    MEMORY = ResourceKind(
        name="memory",
        title="Memory",
        plural_title="Memories",
        description="Details of a particular problem that an agent wrote down to keep",
    )
    ROOK = ResourceKind(
        name="rook",
        title="Rook",
        plural_title="Rooks",
        description="A machine running agents under rook, online while its link to the server is open",
    )
    LIST_KINDS = (AGENT, SKILL, PLAYBOOK, MEMORY, ROOK)

    @classmethod
    def get(cls, name: str) -> ResourceKind:
        """Find a kind by its name.

        Args:
            name: the kind's name, as it appears in request paths and event references

        Returns:
            the kind

        Raises:
            ValidationError: if no such kind is managed here
        """
        for kind in cls.LIST_KINDS:
            if kind.name == name:
                return kind
        raise ValidationError(f"unknown resource kind: {name!r}")


@dataclass(frozen=True)
class ResourceRef:
    """A resource named by its kind and id, as relations and events point at one."""

    kind: str
    id: str

    REF_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._~:-]{0,255}$")

    @classmethod
    def of(cls, kind: str, resource_id: str) -> "ResourceRef":
        """Check and build a reference.

        Args:
            kind: the kind's name
            resource_id: the resource's id within its kind

        Returns:
            the reference

        Raises:
            ValidationError: if the kind is unknown or the id unusable
        """
        ResourceKinds.get(kind)
        if not cls.REF_ID_PATTERN.match(resource_id):
            raise ValidationError(f"unusable {kind} id: {resource_id!r}")
        return cls(kind=kind, id=resource_id)

    @classmethod
    def from_payload(cls, map_payload: object) -> "ResourceRef":
        """Read a reference out of a request body.

        Args:
            map_payload: the decoded `{"kind": ..., "id": ...}` mapping

        Returns:
            the reference

        Raises:
            ValidationError: if it is not a mapping with a usable kind and id
        """
        if not isinstance(map_payload, dict):
            raise ValidationError("a resource reference must be an object with a kind and an id")
        return cls.of(str(map_payload.get("kind") or ""), str(map_payload.get("id") or ""))

    def as_payload(self) -> dict[str, object]:
        """Render the reference as JSON.

        Returns:
            a mapping of the kind and the id
        """
        return {"kind": self.kind, "id": self.id}


@dataclass
class Resource:
    """One managed resource: what it is, its kind's own fields, and when it was last used."""

    kind: str
    id: str
    name: str
    map_attributes: dict[str, object] = field(default_factory=dict)
    origin: ResourceRef | None = None
    created_at: str = ""
    updated_at: str = ""
    last_used_at: str = ""

    def ref(self) -> ResourceRef:
        """Point at this resource.

        Returns:
            its kind and id
        """
        return ResourceRef(kind=self.kind, id=self.id)

    def as_payload(self) -> dict[str, object]:
        """Render the resource as JSON.

        Returns:
            a mapping of every recorded field
        """
        return {
            "kind": self.kind,
            "id": self.id,
            "name": self.name,
            "attributes": self.map_attributes,
            "origin": self.origin.as_payload() if self.origin else None,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "last_used_at": self.last_used_at,
        }


@dataclass
class Relation:
    """A directed edge between two resources, counted every time it happens again."""

    source: ResourceRef
    verb: str
    target: ResourceRef
    first_at: str
    last_at: str
    count: int

    RELATION_VERB_PATTERN = re.compile(r"^[a-z][a-z_]{0,31}$")

    def as_payload(self) -> dict[str, object]:
        """Render the relation as JSON.

        Returns:
            a mapping of both ends, the verb and how often and when it happened
        """
        return {
            "source": self.source.as_payload(),
            "verb": self.verb,
            "target": self.target.as_payload(),
            "first_at": self.first_at,
            "last_at": self.last_at,
            "count": self.count,
        }


@dataclass
class ResourceQuery:
    """A filter over the managed resources, as a reading client asks for them."""

    kind: str | None = None
    text: str | None = None
    since: str | None = None
    order: str = "last_used"
    limit: int = 200

    QUERY_ORDERS = {
        "last_used": "last_used_at DESC, id",
        "updated": "updated_at DESC, id",
        "created": "created_at DESC, id",
        "name": "name COLLATE NOCASE, id",
    }
    QUERY_MAX_LIMIT = 1000


class ResourceStore:
    """Every managed resource, of every kind, and the relations between them, in the database."""

    def __init__(self, database: Database) -> None:
        self._database = database

    @property
    def database(self) -> Database:
        """The database the resources live in, for writes that must go with them in one transaction."""
        return self._database

    @staticmethod
    def now_timestamp() -> str:
        """Produce the timestamp format used throughout the stored resources.

        Returns:
            the current time as an ISO 8601 string in UTC
        """
        return datetime.now(timezone.utc).isoformat(timespec="milliseconds")

    def exists(self, ref: ResourceRef) -> bool:
        """Report whether a resource is stored.

        Args:
            ref: the resource to look for

        Returns:
            True when it is stored
        """
        with self._database.reading() as connection:
            row = connection.execute(
                "SELECT 1 FROM resources WHERE kind = ? AND id = ?",
                (ref.kind, ref.id),
            ).fetchone()
        return row is not None

    def get(self, ref: ResourceRef) -> Resource:
        """Read one resource.

        Args:
            ref: the resource to read

        Returns:
            the resource

        Raises:
            NotFoundError: if it is not stored
        """
        with self._database.reading() as connection:
            row = connection.execute(
                "SELECT * FROM resources WHERE kind = ? AND id = ?",
                (ref.kind, ref.id),
            ).fetchone()
        if row is None:
            raise NotFoundError(f"no such {ref.kind}: {ref.id}")
        return self.resource_of(row)

    def put(self, resource: Resource, connection: sqlite3.Connection | None = None) -> Resource:
        """Store a resource whole, creating it or replacing what was stored, keeping when it was created and,
        unless the resource says otherwise, when it was last used.

        Args:
            resource: the resource; its timestamps are filled in where empty
            connection: a transaction already open, to join; None opens one

        Returns:
            the resource as stored
        """
        if connection is None:
            with self._database.transaction() as opened:
                return self.put(resource, opened)
        now = self.now_timestamp()
        row = connection.execute(
            "SELECT created_at, last_used_at FROM resources WHERE kind = ? AND id = ?",
            (resource.kind, resource.id),
        ).fetchone()
        resource.created_at = row["created_at"] if row is not None else (resource.created_at or now)
        resource.updated_at = now
        resource.last_used_at = resource.last_used_at or (row["last_used_at"] if row is not None else now)
        connection.execute(
            """
            INSERT INTO resources (kind, id, name, attributes, origin_kind, origin_id, created_at, updated_at,
                                   last_used_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (kind, id) DO UPDATE SET
                name = excluded.name, attributes = excluded.attributes, origin_kind = excluded.origin_kind,
                origin_id = excluded.origin_id, updated_at = excluded.updated_at,
                last_used_at = excluded.last_used_at
            """,
            (
                resource.kind,
                resource.id,
                resource.name,
                json.dumps(resource.map_attributes),
                resource.origin.kind if resource.origin else None,
                resource.origin.id if resource.origin else None,
                resource.created_at,
                resource.updated_at,
                resource.last_used_at,
            ),
        )
        return resource

    def delete(self, ref: ResourceRef) -> None:
        """Remove a resource and every relation touching it.

        Args:
            ref: the resource to remove

        Raises:
            NotFoundError: if it is not stored
        """
        with self._database.transaction() as connection:
            removed = connection.execute(
                "DELETE FROM resources WHERE kind = ? AND id = ?",
                (ref.kind, ref.id),
            ).rowcount
            if removed == 0:
                raise NotFoundError(f"no such {ref.kind}: {ref.id}")
            connection.execute(
                """
                DELETE FROM relations
                WHERE (source_kind = ? AND source_id = ?) OR (target_kind = ? AND target_id = ?)
                """,
                (ref.kind, ref.id, ref.kind, ref.id),
            )

    def query(self, query: ResourceQuery) -> list[Resource]:
        """Select resources, filtered and ordered.

        Args:
            query: the kind, the text to look for, the oldest use to keep, the ordering and the page size

        Returns:
            the matching resources

        Raises:
            ValidationError: if the ordering or the page size is unusable
        """
        order = ResourceQuery.QUERY_ORDERS.get(query.order)
        if order is None:
            raise ValidationError(f"unknown order: {query.order!r}")
        if query.limit < 1 or query.limit > ResourceQuery.QUERY_MAX_LIMIT:
            raise ValidationError(f"limit out of range: {query.limit}")
        list_clauses: list[str] = []
        list_values: list[object] = []
        if query.kind:
            ResourceKinds.get(query.kind)
            list_clauses.append("kind = ?")
            list_values.append(query.kind)
        if query.text:
            list_clauses.append("(name LIKE ? ESCAPE '\\' OR id LIKE ? ESCAPE '\\')")
            pattern = "%" + query.text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
            list_values.extend([pattern, pattern])
        if query.since:
            list_clauses.append("last_used_at >= ?")
            list_values.append(query.since)
        where = f"WHERE {' AND '.join(list_clauses)}" if list_clauses else ""
        with self._database.reading() as connection:
            list_rows = connection.execute(
                f"SELECT * FROM resources {where} ORDER BY {order} LIMIT ?",
                (*list_values, query.limit),
            ).fetchall()
        return [self.resource_of(row) for row in list_rows]

    def touch(self, ref: ResourceRef, at: str, connection: sqlite3.Connection) -> None:
        """Record that a resource was used, which moves it up its column on a board.

        Args:
            ref: the resource used
            at: when
            connection: the transaction the use is recorded in
        """
        connection.execute(
            "UPDATE resources SET last_used_at = MAX(last_used_at, ?) WHERE kind = ? AND id = ?",
            (at, ref.kind, ref.id),
        )

    def relate(
        self,
        source: ResourceRef,
        verb: str,
        target: ResourceRef,
        at: str,
        connection: sqlite3.Connection,
    ) -> None:
        """Record that one resource did something to another, counting repeats on one edge.

        Args:
            source: the resource acting
            verb: what it did, such as `uses` or `spawned`
            target: the resource it acted on
            at: when
            connection: the transaction the relation is recorded in

        Raises:
            ValidationError: if the verb is unusable
        """
        if not Relation.RELATION_VERB_PATTERN.match(verb):
            raise ValidationError(f"unusable relation verb: {verb!r}")
        connection.execute(
            """
            INSERT INTO relations (source_kind, source_id, verb, target_kind, target_id, first_at, last_at, count)
            VALUES (?, ?, ?, ?, ?, ?, ?, 1)
            ON CONFLICT (source_kind, source_id, verb, target_kind, target_id) DO UPDATE SET
                last_at = MAX(last_at, excluded.last_at), count = count + 1
            """,
            (source.kind, source.id, verb, target.kind, target.id, at, at),
        )

    def relations(self, ref: ResourceRef | None = None) -> list[Relation]:
        """List relations: all of them, or those starting or ending at one resource.

        Args:
            ref: the resource whose edges to list, or None for every edge

        Returns:
            the relations, most recent first
        """
        with self._database.reading() as connection:
            if ref is None:
                list_rows = connection.execute("SELECT * FROM relations ORDER BY last_at DESC").fetchall()
            else:
                list_rows = connection.execute(
                    """
                    SELECT * FROM relations
                    WHERE (source_kind = ? AND source_id = ?) OR (target_kind = ? AND target_id = ?)
                    ORDER BY last_at DESC
                    """,
                    (ref.kind, ref.id, ref.kind, ref.id),
                ).fetchall()
        return [
            Relation(
                source=ResourceRef(kind=row["source_kind"], id=row["source_id"]),
                verb=row["verb"],
                target=ResourceRef(kind=row["target_kind"], id=row["target_id"]),
                first_at=row["first_at"],
                last_at=row["last_at"],
                count=row["count"],
            )
            for row in list_rows
        ]

    @staticmethod
    def resource_of(row: sqlite3.Row) -> Resource:
        """Read a resource out of a database row.

        Args:
            row: a row of the resources table

        Returns:
            the resource it holds
        """
        origin = None
        if row["origin_kind"] and row["origin_id"]:
            origin = ResourceRef(kind=row["origin_kind"], id=row["origin_id"])
        return Resource(
            kind=row["kind"],
            id=row["id"],
            name=row["name"],
            map_attributes=json.loads(row["attributes"]),
            origin=origin,
            created_at=row["created_at"],
            updated_at=row["updated_at"],
            last_used_at=row["last_used_at"],
        )
