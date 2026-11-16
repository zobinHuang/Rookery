import re
from collections.abc import Iterator
from contextlib import contextmanager
from roost.errors import ValidationError
from roost.resources import Resource, ResourceQuery, ResourceRef, ResourceStore


class RecordStore:
    """The records of one kind of resource, each a JSON object, kept as resources in the database: the
    record is the resource's attributes, and its `name` field the resource's name."""

    RECORD_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
    RECORD_SLUG_SANITIZE_PATTERN = re.compile(r"[^a-z0-9]+")

    def __init__(self, resources: ResourceStore, kind: str) -> None:
        self._resources = resources
        self._kind = kind

    @classmethod
    def slugify(cls, text: str, fallback: str) -> str:
        """Render free text as an identifier that is safe to use as a record id.

        Args:
            text: the text to render
            fallback: the identifier to use when nothing usable survives

        Returns:
            a lowercase identifier of letters, digits, dots, dashes and underscores
        """
        slug = cls.RECORD_SLUG_SANITIZE_PATTERN.sub("-", text.strip().lower())
        slug = slug.strip("-._")[:128]
        return slug if cls.RECORD_ID_PATTERN.match(slug) else fallback

    def validate_id(self, record_id: str) -> str:
        """Check that an identifier is a usable record id.

        Args:
            record_id: the identifier taken from a request path or body

        Returns:
            the identifier unchanged

        Raises:
            ValidationError: if it is not
        """
        if not self.RECORD_ID_PATTERN.match(record_id):
            raise ValidationError(f"unusable {self._kind} id: {record_id!r}")
        return record_id

    def exists(self, record_id: str) -> bool:
        """Report whether a record is stored.

        Args:
            record_id: the record to look for

        Returns:
            True when the record exists
        """
        return self._resources.exists(self._ref(record_id))

    def read(self, record_id: str) -> dict[str, object]:
        """Read one stored record.

        Args:
            record_id: the record to read

        Returns:
            the record

        Raises:
            ValidationError: if the identifier is unusable
            NotFoundError: if no such record is stored
        """
        return dict(self._resources.get(self._ref(record_id)).map_attributes)

    def write(self, record_id: str, map_record: dict[str, object]) -> None:
        """Store one record, replacing any earlier version of it.

        Args:
            record_id: the record to write
            map_record: the record body
        """
        self._resources.put(Resource(
            kind=self._kind,
            id=self.validate_id(record_id),
            name=str(map_record.get("name") or record_id),
            map_attributes=dict(map_record),
        ))

    def delete(self, record_id: str) -> None:
        """Remove one stored record.

        Args:
            record_id: the record to remove

        Raises:
            ValidationError: if the identifier is unusable
            NotFoundError: if no such record is stored
        """
        self._resources.delete(self._ref(record_id))

    def list_all(self) -> list[dict[str, object]]:
        """Read every stored record of this kind.

        Returns:
            the records, in no particular order
        """
        return [
            dict(resource.map_attributes)
            for resource in self._resources.query(ResourceQuery(kind=self._kind, limit=ResourceQuery.QUERY_MAX_LIMIT))
        ]

    @contextmanager
    def locked(self) -> Iterator[None]:
        """Hold the database for the duration of the block, so a read and the write after it are one step.

        Yields:
            nothing; the database is released when the block ends
        """
        with self._resources.database.reading():
            yield

    def _ref(self, record_id: str) -> ResourceRef:
        return ResourceRef(kind=self._kind, id=self.validate_id(record_id))
