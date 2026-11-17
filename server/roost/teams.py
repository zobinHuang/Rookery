from dataclasses import dataclass
from roost.errors import NotFoundError, ValidationError
from roost.events import EventLog, EventVerbs
from roost.resources import Resource, ResourceKinds, ResourceQuery, ResourceRef, ResourceStore


@dataclass(frozen=True)
class TeamLimits:
    """How far agents of a team may go messaging one another before roost holds a message for the user: a
    backstop against two agents answering each other without end, which the team skill should prevent."""

    LIMITS_THREAD_HOPS = 20
    LIMITS_SENDS_PER_WINDOW = 30
    LIMITS_WINDOW_MINUTES = 10

    thread_hops: int = LIMITS_THREAD_HOPS
    sends_per_window: int = LIMITS_SENDS_PER_WINDOW
    window_minutes: int = LIMITS_WINDOW_MINUTES

    @classmethod
    def of(cls, team: Resource) -> "TeamLimits":
        """A team's limits, its own where it sets them, the defaults otherwise."""
        map_limits = team.map_attributes.get("limits")
        if not isinstance(map_limits, dict):
            return cls()
        return cls(
            thread_hops=cls._positive(map_limits.get("thread_hops"), cls.LIMITS_THREAD_HOPS),
            sends_per_window=cls._positive(map_limits.get("sends_per_window"), cls.LIMITS_SENDS_PER_WINDOW),
            window_minutes=cls._positive(map_limits.get("window_minutes"), cls.LIMITS_WINDOW_MINUTES),
        )

    @classmethod
    def loosest(cls, list_teams: list[Resource]) -> "TeamLimits":
        """The most a message between agents sharing several teams may go: each limit the loosest of theirs."""
        list_limits = [cls.of(team) for team in list_teams] or [cls()]
        return cls(
            thread_hops=max(limits.thread_hops for limits in list_limits),
            sends_per_window=max(limits.sends_per_window for limits in list_limits),
            window_minutes=min(limits.window_minutes for limits in list_limits),
        )

    @staticmethod
    def _positive(value: object, default: int) -> int:
        return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else default


class TeamRoster:
    """Who is in which team and with what duty, kept in each team's `members` attribute, and every agent's
    card: who it is (its role), what it does now (its focus), where it runs and how it stands. An agent may
    be in several teams. Rookery's own agents, as Raven's conversations, join a team when the user puts
    them in it, to direct it for the user, and are told apart in every roster by their rook."""

    ROSTER_MEMBERS_KEY = "members"
    ROSTER_DUTY_MAX_CHARS = 300
    ROSTER_ROOKERY_ROOK = "rookery"
    ROSTER_CARD_FIELDS = (
        "title",
        "role",
        "focus",
        "focus_at",
        "state",
        "rook_name",
        "cwd",
        "git_branch",
        "harness",
    )

    def __init__(self, resources: ResourceStore, events: EventLog) -> None:
        self._resources = resources
        self._events = events

    def join(self, team_id: str, agent_id: str, duty: str, actor: ResourceRef | None) -> Resource:
        """Put an agent in a team with a duty, or give a member a new duty.

        Args:
            team_id: the team
            agent_id: the agent
            duty: what the agent does in this team, or empty
            actor: the agent that made the change, or None for a person

        Returns:
            the team as stored

        Raises:
            ValidationError: if the duty is too long
            NotFoundError: if there is no such team or agent
        """
        duty = duty.strip()
        if len(duty) > self.ROSTER_DUTY_MAX_CHARS:
            raise ValidationError(f"a duty is at most {self.ROSTER_DUTY_MAX_CHARS} characters")
        team_ref = ResourceRef.of(ResourceKinds.TEAM.name, team_id)
        agent_ref = ResourceRef.of(ResourceKinds.AGENT.name, agent_id)
        self._resources.get(agent_ref)
        with self._resources.database.transaction() as connection:
            team = self._resources.get(team_ref)
            map_members = self.members_of(team)
            map_member = dict(map_members.get(agent_id) or {})
            map_member["duty"] = duty
            map_member.setdefault("joined_at", ResourceStore.now_timestamp())
            map_members[agent_id] = map_member
            team.map_attributes[self.ROSTER_MEMBERS_KEY] = map_members
            self._resources.put(team, connection)
        self._events.record_change(actor, EventVerbs.UPDATED, team_ref)
        return self._resources.get(team_ref)

    def leave(self, team_id: str, agent_id: str, actor: ResourceRef | None) -> Resource:
        """Take an agent out of a team.

        Raises:
            NotFoundError: if there is no such team, or the agent is not in it
        """
        team_ref = ResourceRef.of(ResourceKinds.TEAM.name, team_id)
        with self._resources.database.transaction() as connection:
            team = self._resources.get(team_ref)
            map_members = self.members_of(team)
            if agent_id not in map_members:
                raise NotFoundError(f"agent {agent_id} is not in team {team.name}")
            del map_members[agent_id]
            team.map_attributes[self.ROSTER_MEMBERS_KEY] = map_members
            self._resources.put(team, connection)
        self._events.record_change(actor, EventVerbs.UPDATED, team_ref)
        return self._resources.get(team_ref)

    def teams(self) -> list[Resource]:
        """Every team, by name."""
        return self._resources.query(ResourceQuery(
            kind=ResourceKinds.TEAM.name,
            order="name",
            limit=ResourceQuery.QUERY_MAX_LIMIT,
        ))

    def teams_of(self, agent_id: str) -> list[Resource]:
        """The teams an agent is in, by name."""
        return [team for team in self.teams() if agent_id in self.members_of(team)]

    def shared_teams(self, first_agent_id: str, second_agent_id: str) -> list[Resource]:
        """The teams two agents are both in."""
        return [
            team
            for team in self.teams()
            if first_agent_id in self.members_of(team) and second_agent_id in self.members_of(team)
        ]

    def is_rookery_own(self, agent: Resource) -> bool:
        """Whether an agent is one of Rookery's own, as Raven's conversations, which runs for the user."""
        return agent.map_attributes.get("rook_name") == self.ROSTER_ROOKERY_ROOK

    def card(self, agent: Resource) -> dict[str, object]:
        """What another agent needs to know of an agent: its id, its name, who it is, what it does now,
        where it runs and how it stands."""
        map_card: dict[str, object] = {"id": agent.id, "name": agent.name}
        for key in self.ROSTER_CARD_FIELDS:
            map_card[key] = agent.map_attributes.get(key)
        map_machine = agent.map_attributes.get("machine")
        map_card["hostname"] = map_machine.get("hostname") if isinstance(map_machine, dict) else None
        map_card["last_used_at"] = agent.last_used_at
        return map_card

    def roster(self, team: Resource) -> dict[str, object]:
        """A team with every member's card and duty, those whose agent is gone left out.

        Returns:
            the team's payload, with `members` as a list of cards each carrying its `duty`
        """
        map_payload = team.as_payload()
        list_members: list[dict[str, object]] = []
        for agent_id, map_member in self.members_of(team).items():
            agent_ref = ResourceRef(kind=ResourceKinds.AGENT.name, id=agent_id)
            if not self._resources.exists(agent_ref):
                continue
            map_card = self.card(self._resources.get(agent_ref))
            map_card["duty"] = map_member.get("duty") or ""
            map_card["joined_at"] = map_member.get("joined_at")
            list_members.append(map_card)
        map_payload["members"] = list_members
        return map_payload

    @classmethod
    def members_of(cls, team: Resource) -> dict[str, dict[str, object]]:
        """A team's members, by agent id, each with its duty and when it joined."""
        map_members = team.map_attributes.get(cls.ROSTER_MEMBERS_KEY)
        if not isinstance(map_members, dict):
            return {}
        return {
            str(agent_id): dict(map_member) if isinstance(map_member, dict) else {}
            for agent_id, map_member in map_members.items()
        }
