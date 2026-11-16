from roost.errors import ValidationError
from roost.events import EventLog, EventVerbs
from roost.playbooks import PlaybookIndex
from roost.records import RecordStore
from roost.resources import Resource, ResourceKinds, ResourceRef, ResourceStore
from roost.skills import SkillIndex


class ResourceCatalog:
    """Changes to resources through the API, whatever their kind: a skill or a playbook goes through its own
    index, which resolves versions and checks pins; any other kind is a name and free attributes. Every
    change is logged as an event, by the agent the request names as `actor`, or else by a person."""

    CATALOG_NAME_MAX_CHARS = 200

    def __init__(
        self,
        resources: ResourceStore,
        events: EventLog,
        skills: SkillIndex,
        playbooks: PlaybookIndex,
    ) -> None:
        self._resources = resources
        self._events = events
        self._skills = skills
        self._playbooks = playbooks

    def create(self, kind: str, map_body: dict[str, object]) -> Resource:
        """Add a resource.

        Args:
            kind: the kind's name
            map_body: the resource as the kind expects it, plus an optional `actor`

        Returns:
            the stored resource

        Raises:
            ValidationError: if the kind or a field is unusable
            ConflictError: if a resource of that id already exists
        """
        actor = self._actor_of(map_body)
        if kind == ResourceKinds.SKILL.name:
            ref = ResourceRef(kind=kind, id=self._skills.register(map_body).id)
        elif kind == ResourceKinds.PLAYBOOK.name:
            ref = ResourceRef(kind=kind, id=self._playbooks.create(map_body).id)
        else:
            ResourceKinds.get(kind)
            name = self._name_of(map_body)
            resource_id = str(map_body.get("id") or "").strip() or RecordStore.slugify(name, fallback=kind)
            ref = ResourceRef.of(kind, resource_id)
            self._resources.put(Resource(
                kind=kind,
                id=ref.id,
                name=name,
                map_attributes=self._attributes_of(map_body),
                origin=actor,
            ))
        self._events.record_change(actor, EventVerbs.CREATED, ref)
        return self._resources.get(ref)

    def update(self, kind: str, resource_id: str, map_body: dict[str, object]) -> Resource:
        """Change a resource; a field left out is left alone, and `attributes` are merged in.

        Args:
            kind: the kind's name
            resource_id: the resource's id
            map_body: the fields to change, plus an optional `actor`

        Returns:
            the stored resource

        Raises:
            ValidationError: if the kind, the id or a field is unusable
            NotFoundError: if no such resource is managed
        """
        actor = self._actor_of(map_body)
        ref = ResourceRef.of(kind, resource_id)
        if kind == ResourceKinds.SKILL.name:
            self._skills.update(resource_id, map_body)
        elif kind == ResourceKinds.PLAYBOOK.name:
            self._playbooks.update(resource_id, map_body)
        else:
            with self._resources.database.transaction() as connection:
                resource = self._resources.get(ref)
                if "name" in map_body:
                    resource.name = self._name_of(map_body)
                resource.map_attributes.update(self._attributes_of(map_body))
                self._resources.put(resource, connection)
        self._events.record_change(actor, EventVerbs.UPDATED, ref)
        return self._resources.get(ref)

    def delete(self, kind: str, resource_id: str, map_body: dict[str, object]) -> None:
        """Remove a resource and its relations.

        Args:
            kind: the kind's name
            resource_id: the resource's id
            map_body: an optional `actor`

        Raises:
            ValidationError: if the kind or the id is unusable
            NotFoundError: if no such resource is managed
        """
        actor = self._actor_of(map_body)
        ref = ResourceRef.of(kind, resource_id)
        if kind == ResourceKinds.SKILL.name:
            self._skills.delete(resource_id)
        elif kind == ResourceKinds.PLAYBOOK.name:
            self._playbooks.delete(resource_id)
        else:
            self._resources.delete(ref)
        self._events.record_change(actor, EventVerbs.DELETED, ref)

    def _name_of(self, map_body: dict[str, object]) -> str:
        name = str(map_body.get("name") or "").strip()
        if not name:
            raise ValidationError("a resource needs a name")
        if len(name) > self.CATALOG_NAME_MAX_CHARS:
            raise ValidationError(f"a resource name is longer than {self.CATALOG_NAME_MAX_CHARS} characters")
        return name

    @staticmethod
    def _attributes_of(map_body: dict[str, object]) -> dict[str, object]:
        map_attributes = map_body.get("attributes")
        if map_attributes is None:
            return {}
        if not isinstance(map_attributes, dict):
            raise ValidationError("a resource's attributes must be an object")
        return dict(map_attributes)

    @staticmethod
    def _actor_of(map_body: dict[str, object]) -> ResourceRef | None:
        map_actor = map_body.get("actor")
        return ResourceRef.from_payload(map_actor) if map_actor is not None else None
