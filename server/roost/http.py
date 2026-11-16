import json
import secrets
import ssl
import sys
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
from roost import ROOST_VERSION
from roost.config import ServerConfig
from roost.catalog import ResourceCatalog
from roost.database import Database
from roost.errors import (
    AuthError,
    BusyError,
    NotFoundError,
    PayloadTooLargeError,
    RoostError,
    ValidationError,
)
from roost.events import EventLog
from roost.link import LinkHub
from roost.messages import DeliveryStore
from roost.playbooks import PlaybookIndex
from roost.resources import ResourceKinds, ResourceQuery, ResourceRef, ResourceStore
from roost.skills import SkillIndex
from roost.store import SessionMeta, SessionQuery, SessionStore, TranscriptTitles


class RoostRequestHandler(BaseHTTPRequestHandler):
    """The HTTP surface through which clients upload agent session transcripts."""

    HANDLER_API_PREFIX = "v1"
    HANDLER_BEARER_PREFIX = "Bearer "

    server_version = f"roost/{ROOST_VERSION}"
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:
        """Serve a health check or a session listing."""
        self._dispatch("GET")

    def do_POST(self) -> None:
        """Serve a session registration or a session close."""
        self._dispatch("POST")

    def do_PUT(self) -> None:
        """Serve a transcript append."""
        self._dispatch("PUT")

    def do_PATCH(self) -> None:
        """Serve a change to an indexed skill or playbook."""
        self._dispatch("PATCH")

    def do_DELETE(self) -> None:
        """Serve the removal of an indexed skill or playbook."""
        self._dispatch("DELETE")

    def log_message(self, format: str, *args: object) -> None:
        """Write one request line to stderr.

        Args:
            format: the printf-style template the base class supplies
            args: the template's arguments
        """
        sys.stderr.write(
            "roost %s %s\n"
            % (
                self.address_string(),
                format % args,
            )
        )

    def _dispatch(self, method: str) -> None:
        try:
            parsed = urlparse(self.path)
            list_segments = [segment for segment in parsed.path.split("/") if segment]
            if not list_segments or list_segments[0] != self.HANDLER_API_PREFIX:
                raise NotFoundError(f"no such route: {parsed.path}")
            self._route(
                method=method,
                list_segments=list_segments[1:],
                map_query=parse_qs(parsed.query),
            )
        except RoostError as err:
            self._respond_error(err)
        except OSError as err:
            self._respond_error(RoostError(f"storage failure: {err}"))

    def _route(
        self,
        method: str,
        list_segments: list[str],
        map_query: dict[str, list[str]],
    ) -> None:
        if list_segments == ["healthz"] and method == "GET":
            self._respond_json(
                HTTPStatus.OK,
                {
                    "ok": True,
                    "version": ROOST_VERSION,
                    "link_port": self.server.link.bound_port(),
                },
            )
            return

        self._authenticate()

        collection = list_segments[0] if list_segments else ""
        if collection in ("sessions", "machines", "accounts"):
            self._route_sessions(method, list_segments, map_query)
        elif collection == "skills":
            self._route_skills(method, list_segments, map_query)
        elif collection == "playbooks":
            self._route_playbooks(method, list_segments, map_query)
        elif collection in ("kinds", "resources", "relations"):
            self._route_resources(method, list_segments, map_query)
        elif collection == "events":
            self._route_events(method, list_segments, map_query)
        elif collection == "messages":
            self._route_messages(method, list_segments, map_query)
        else:
            raise NotFoundError(self._no_such_route(method, list_segments))

    def _no_such_route(self, method: str, list_segments: list[str]) -> str:
        return (
            f"no such route: {method} /{self.HANDLER_API_PREFIX}/"
            + "/".join(list_segments)
        )

    def _route_sessions(
        self,
        method: str,
        list_segments: list[str],
        map_query: dict[str, list[str]],
    ) -> None:
        if list_segments == ["sessions"] and method == "GET":
            self._handle_query(map_query)
            return

        if list_segments == ["machines"] and method == "GET":
            self._respond_json(
                HTTPStatus.OK,
                {"machines": [s.as_payload() for s in self._store().list_machines()]},
            )
            return

        if list_segments == ["accounts"] and method == "GET":
            self._respond_json(
                HTTPStatus.OK,
                {"accounts": [s.as_payload() for s in self._store().list_accounts()]},
            )
            return

        if len(list_segments) == 2 and list_segments[0] == "sessions" and method == "GET":
            self._respond_json(
                HTTPStatus.OK,
                self._store().meta_of(list_segments[1]).as_payload(),
            )
            return

        if len(list_segments) == 3 and list_segments[0] == "sessions":
            session_id = list_segments[1]
            action = list_segments[2]
            if action == "begin" and method == "POST":
                self._handle_begin(session_id)
                return
            if action == "data" and method == "PUT":
                self._handle_data(session_id, map_query)
                return
            if action == "close" and method == "POST":
                self._handle_close(session_id)
                return
            if action == "transcript" and method == "GET":
                self._handle_transcript(session_id, map_query)
                return

        raise NotFoundError(self._no_such_route(method, list_segments))

    def _route_skills(
        self,
        method: str,
        list_segments: list[str],
        map_query: dict[str, list[str]],
    ) -> None:
        skills = self._skills()
        if list_segments == ["skills"]:
            if method == "GET":
                list_record = skills.query(
                    text=self._query_text(map_query, "q"),
                    repo=self._query_text(map_query, "repo"),
                    limit=self._index_limit(map_query, SkillIndex.INDEX_QUERY_DEFAULT_LIMIT),
                )
                self._respond_json(
                    HTTPStatus.OK,
                    {"skills": [record.as_payload() for record in list_record]},
                )
                return
            if method == "POST":
                self._respond_json(
                    HTTPStatus.OK,
                    skills.register(self._read_json_body()).as_payload(),
                )
                return

        if len(list_segments) == 2:
            skill_id = list_segments[1]
            if method == "GET":
                self._respond_json(HTTPStatus.OK, skills.get(skill_id).as_payload())
                return
            if method == "PATCH":
                self._respond_json(
                    HTTPStatus.OK,
                    skills.update(skill_id, self._read_json_body()).as_payload(),
                )
                return
            if method == "DELETE":
                self._read_body()
                skills.delete(skill_id)
                self._respond_json(HTTPStatus.OK, {"ok": True})
                return

        if len(list_segments) == 3 and method in ("GET", "POST"):
            skill_id = list_segments[1]
            action = list_segments[2]
            if action == "versions" and method == "GET":
                record = skills.get(skill_id)
                self._respond_json(
                    HTTPStatus.OK,
                    {
                        "skill_id": record.id,
                        "default_ref": record.default_ref,
                        "versions": [v.as_payload() for v in record.list_versions],
                    },
                )
                return
            if action == "refresh" and method == "POST":
                self._read_body()
                record, version = skills.resolve_version(skill_id, SkillIndex.INDEX_PIN_LATEST)
                self._respond_json(
                    HTTPStatus.OK,
                    {
                        "skill_id": record.id,
                        "default_ref": record.default_ref,
                        "version": version.as_payload(),
                    },
                )
                return

        raise NotFoundError(self._no_such_route(method, list_segments))

    def _route_playbooks(
        self,
        method: str,
        list_segments: list[str],
        map_query: dict[str, list[str]],
    ) -> None:
        playbooks = self._playbooks()
        if list_segments == ["playbooks"]:
            if method == "GET":
                list_record = playbooks.query(
                    text=self._query_text(map_query, "q"),
                    limit=self._index_limit(
                        map_query,
                        PlaybookIndex.INDEX_QUERY_DEFAULT_LIMIT,
                    ),
                )
                self._respond_json(
                    HTTPStatus.OK,
                    {"playbooks": [record.as_payload() for record in list_record]},
                )
                return
            if method == "POST":
                self._respond_json(
                    HTTPStatus.CREATED,
                    playbooks.create(self._read_json_body()).as_payload(),
                )
                return

        if len(list_segments) == 2:
            playbook_id = list_segments[1]
            if method == "GET":
                self._respond_json(HTTPStatus.OK, playbooks.get(playbook_id).as_payload())
                return
            if method == "PATCH":
                self._respond_json(
                    HTTPStatus.OK,
                    playbooks.update(playbook_id, self._read_json_body()).as_payload(),
                )
                return
            if method == "DELETE":
                self._read_body()
                playbooks.delete(playbook_id)
                self._respond_json(HTTPStatus.OK, {"ok": True})
                return

        if len(list_segments) == 3 and list_segments[2] == "resolve" and method == "GET":
            self._respond_json(
                HTTPStatus.OK,
                playbooks.resolve(list_segments[1]).as_payload(),
            )
            return

        raise NotFoundError(self._no_such_route(method, list_segments))

    def _route_resources(
        self,
        method: str,
        list_segments: list[str],
        map_query: dict[str, list[str]],
    ) -> None:
        catalog = self._catalog()
        if list_segments == ["kinds"] and method == "GET":
            self._respond_json(HTTPStatus.OK, {"kinds": [kind.as_payload() for kind in ResourceKinds.LIST_KINDS]})
            return
        if list_segments == ["relations"] and method == "GET":
            kind = self._query_text(map_query, "kind")
            resource_id = self._query_text(map_query, "id")
            ref = ResourceRef.of(kind, resource_id) if kind and resource_id else None
            self._respond_json(
                HTTPStatus.OK,
                {"relations": [relation.as_payload() for relation in self.server.resources.relations(ref)]},
            )
            return
        if list_segments == ["resources"] and method == "GET":
            query = ResourceQuery(
                kind=self._query_text(map_query, "kind"),
                text=self._query_text(map_query, "q"),
                since=self._query_text(map_query, "since"),
                order=self._query_text(map_query, "order") or "last_used",
                limit=self._index_limit(map_query, ResourceQuery.QUERY_MAX_LIMIT),
            )
            self._respond_json(
                HTTPStatus.OK,
                {"resources": [resource.as_payload() for resource in self.server.resources.query(query)]},
            )
            return
        if len(list_segments) == 2 and list_segments[0] == "resources" and method == "POST":
            self._respond_json(HTTPStatus.CREATED, catalog.create(list_segments[1], self._read_json_body()).as_payload())
            return
        if len(list_segments) == 3 and list_segments[0] == "resources":
            kind, resource_id = list_segments[1], list_segments[2]
            if method == "GET":
                self._respond_json(
                    HTTPStatus.OK,
                    self.server.resources.get(ResourceRef.of(kind, resource_id)).as_payload(),
                )
                return
            if method == "PATCH":
                self._respond_json(
                    HTTPStatus.OK,
                    catalog.update(kind, resource_id, self._read_json_body()).as_payload(),
                )
                return
            if method == "DELETE":
                catalog.delete(kind, resource_id, self._read_json_body())
                self._respond_json(HTTPStatus.OK, {"ok": True})
                return
        raise NotFoundError(self._no_such_route(method, list_segments))

    def _route_events(
        self,
        method: str,
        list_segments: list[str],
        map_query: dict[str, list[str]],
    ) -> None:
        events = self.server.events
        if list_segments == ["events"] and method == "POST":
            list_reports = self._read_json_body().get("events")
            if not isinstance(list_reports, list):
                raise ValidationError("the body needs an events list")
            self._respond_json(
                HTTPStatus.OK,
                {"events": [event.as_payload() for event in events.record(list_reports)]},
            )
            return
        if list_segments == ["events"] and method == "GET":
            limit = self._index_limit(map_query, EventLog.EVENT_PAGE_MAX)
            if "after" in map_query:
                list_events = events.after(self._query_int(map_query, "after"), limit)
            else:
                list_events = events.latest(limit)
            self._respond_json(HTTPStatus.OK, {"events": [event.as_payload() for event in list_events]})
            return
        if list_segments == ["events", "stream"] and method == "GET":
            after = self._query_int(map_query, "after") if "after" in map_query else 0
            self._stream_events(after)
            return
        raise NotFoundError(self._no_such_route(method, list_segments))

    def _route_messages(
        self,
        method: str,
        list_segments: list[str],
        map_query: dict[str, list[str]],
    ) -> None:
        if list_segments == ["messages"] and method == "POST":
            map_body = self._read_json_body()
            map_actor = map_body.get("actor")
            sender = ResourceRef.from_payload(map_actor) if map_actor else EventLog.EVENT_PERSON
            delivery = self.server.link.send_to_agent(
                sender,
                str(map_body.get("to") or ""),
                str(map_body.get("text") or ""),
            )
            self._respond_json(HTTPStatus.CREATED, delivery.as_payload())
            return
        if list_segments == ["messages"] and method == "GET":
            list_deliveries = self.server.deliveries.list_recent(
                self._query_text(map_query, "agent"),
                self._index_limit(map_query, DeliveryStore.DELIVERY_LIST_MAX),
            )
            self._respond_json(
                HTTPStatus.OK,
                {"messages": [delivery.as_payload() for delivery in list_deliveries]},
            )
            return
        if len(list_segments) == 2 and method == "GET":
            self._respond_json(HTTPStatus.OK, self.server.deliveries.get(list_segments[1]).as_payload())
            return
        raise NotFoundError(self._no_such_route(method, list_segments))

    def _stream_events(self, after: int) -> None:
        """Send every event after a sequence number as server-sent events, then each new one as it is
        logged, with a comment now and then so idle proxies keep the connection open, until the client
        goes away."""
        if not self.server.stream_slots.acquire(blocking=False):
            raise BusyError("too many event streams are open; try again later")
        try:
            self.close_connection = True
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            cursor = after
            while not self.server.is_stopping:
                list_events = self.server.events.wait_after(cursor, RoostServer.SERVER_STREAM_HEARTBEAT_SECONDS)
                if not list_events:
                    self.wfile.write(b": keepalive\n\n")
                for event in list_events:
                    body = json.dumps(event.as_payload())
                    self.wfile.write(f"id: {event.seq}\nevent: event\ndata: {body}\n\n".encode("utf-8"))
                    cursor = event.seq
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass
        finally:
            self.server.stream_slots.release()

    def _index_limit(self, map_query: dict[str, list[str]], default: int) -> int:
        if "limit" not in map_query:
            return default
        limit = self._query_int(map_query, "limit")
        if limit < 1 or limit > SessionQuery.QUERY_MAX_LIMIT:
            raise ValidationError(f"limit out of range: {limit}")
        return limit

    def _handle_begin(self, session_id: str) -> None:
        meta = SessionMeta.from_request(
            session_id=session_id,
            map_body=self._read_json_body(),
        )
        cursor = self._store().begin(meta)
        self._respond_json(HTTPStatus.OK, cursor.as_payload())

    def _handle_data(
        self,
        session_id: str,
        map_query: dict[str, list[str]],
    ) -> None:
        offset = self._query_int(map_query, "offset")
        do_reset = self._query_flag(map_query, "reset")
        chunk = self._read_body()
        cursor = self._store().append(
            session_id=session_id,
            offset=offset,
            chunk=chunk,
            do_reset=do_reset,
        )
        if TranscriptTitles.TITLE_MARKER in chunk:
            title = self._store().title_of(session_id)
            if title:
                self.server.events.rename(session_id, title)
        self._respond_json(HTTPStatus.OK, cursor.as_payload())

    def _handle_close(self, session_id: str) -> None:
        self._read_body()
        meta = self._store().close(session_id)
        self._respond_json(
            HTTPStatus.OK,
            {
                "ok": True,
                "closed_at": meta.closed_at,
            },
        )

    def _handle_query(self, map_query: dict[str, list[str]]) -> None:
        self._respond_json(
            HTTPStatus.OK,
            self._store().query(self._build_query(map_query)).as_payload(),
        )

    def _build_query(self, map_query: dict[str, list[str]]) -> SessionQuery:
        limit = SessionQuery.QUERY_DEFAULT_LIMIT
        if "limit" in map_query:
            limit = self._query_int(map_query, "limit")
        if limit < 1 or limit > SessionQuery.QUERY_MAX_LIMIT:
            raise ValidationError(f"limit out of range: {limit}")

        agent = self._query_text(map_query, "agent")
        if agent and agent not in SessionMeta.SESSION_AGENTS:
            raise ValidationError(f"unknown agent: {agent!r}")
        status = self._query_text(map_query, "status")
        if status and status not in SessionQuery.QUERY_STATUSES:
            raise ValidationError(f"unknown status: {status!r}")
        time_field = self._query_text(map_query, "time") or "updated_at"
        if not time_field.endswith("_at"):
            time_field = f"{time_field}_at"
        if time_field not in SessionQuery.QUERY_TIME_FIELDS:
            raise ValidationError(f"unknown time field: {time_field!r}")

        since = self._query_text(map_query, "since")
        until = self._query_text(map_query, "until")
        return SessionQuery(
            agent=agent,
            account=self._query_text(map_query, "account"),
            hostname=self._query_text(map_query, "hostname"),
            project=self._query_text(map_query, "project"),
            branch=self._query_text(map_query, "branch"),
            status=status,
            since=SessionQuery.parse_timestamp(since) if since else None,
            until=SessionQuery.parse_timestamp(until) if until else None,
            time_field=time_field,
            limit=limit,
            cursor=self._query_text(map_query, "cursor"),
        )

    def _handle_transcript(
        self,
        session_id: str,
        map_query: dict[str, list[str]],
    ) -> None:
        offset = 0
        if "offset" in map_query:
            offset = self._query_int(map_query, "offset")
        limit = None
        if "limit" in map_query:
            limit = self._query_int(map_query, "limit")
            if limit < 1:
                raise ValidationError(f"limit out of range: {limit}")
        chunk = self._store().read_transcript(
            session_id=session_id,
            offset=offset,
            limit=limit,
        )
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Content-Length", str(len(chunk.data)))
        self.send_header("X-Rook-Offset", str(chunk.offset))
        self.send_header("X-Rook-Total", str(chunk.total))
        self.end_headers()
        self.wfile.write(chunk.data)

    def _authenticate(self) -> None:
        header = self.headers.get("Authorization", "")
        if not header.startswith(self.HANDLER_BEARER_PREFIX):
            raise AuthError("request carried no bearer token")
        offered = header[len(self.HANDLER_BEARER_PREFIX):]
        if not secrets.compare_digest(offered, self._config().token):
            raise AuthError("bearer token not accepted")

    def _read_body(self) -> bytes:
        encoding = (self.headers.get("Transfer-Encoding") or "").lower()
        if "chunked" in encoding:
            raise ValidationError(
                "chunked request bodies are not accepted; send Content-Length"
            )
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            return b""
        try:
            length = int(raw_length)
        except ValueError as err:
            raise ValidationError(f"unusable Content-Length: {raw_length!r}") from err
        if length < 0:
            raise ValidationError(f"negative Content-Length: {length}")
        if length > self._config().max_body_bytes:
            raise PayloadTooLargeError(
                f"body of {length} bytes exceeds the {self._config().max_body_bytes}"
                " byte limit"
            )
        return self.rfile.read(length)

    def _read_json_body(self) -> dict[str, object]:
        body = self._read_body()
        if not body:
            return {}
        try:
            map_body = json.loads(body)
        except json.JSONDecodeError as err:
            raise ValidationError("request body is not valid JSON") from err
        if not isinstance(map_body, dict):
            raise ValidationError("request body is not a JSON object")
        return map_body

    def _query_int(self, map_query: dict[str, list[str]], name: str) -> int:
        list_values = map_query.get(name) or []
        if not list_values:
            raise ValidationError(f"missing query parameter: {name}")
        try:
            return int(list_values[0])
        except ValueError as err:
            raise ValidationError(
                f"query parameter {name} is not an integer: {list_values[0]!r}"
            ) from err

    def _query_text(self, map_query: dict[str, list[str]], name: str) -> str | None:
        list_values = map_query.get(name) or []
        if not list_values:
            return None
        return list_values[0].strip() or None

    def _query_flag(self, map_query: dict[str, list[str]], name: str) -> bool:
        list_values = map_query.get(name) or []
        if not list_values:
            return False
        return list_values[0] in ("1", "true", "yes")

    def _config(self) -> ServerConfig:
        return self.server.config

    def _store(self) -> SessionStore:
        return self.server.store

    def _skills(self) -> SkillIndex:
        return self.server.skills

    def _playbooks(self) -> PlaybookIndex:
        return self.server.playbooks

    def _catalog(self) -> ResourceCatalog:
        return self.server.catalog

    def _respond_json(self, status: HTTPStatus, map_payload: dict[str, object]) -> None:
        body = json.dumps(map_payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _respond_error(self, err: RoostError) -> None:
        self.close_connection = True
        self._respond_json(HTTPStatus(err.ERROR_HTTP_STATUS), err.as_payload())


class RoostServer(ThreadingHTTPServer):
    """A threaded HTTP server that carries the configuration, the session store and the resources."""

    daemon_threads = True
    allow_reuse_address = True
    SERVER_STREAMS_MAX = 32
    SERVER_STREAM_HEARTBEAT_SECONDS = 15

    def __init__(
        self,
        config: ServerConfig,
        store: SessionStore,
        resources: ResourceStore | None = None,
        skills: SkillIndex | None = None,
        playbooks: PlaybookIndex | None = None,
    ) -> None:
        self.config = config
        self.store = store
        self.resources = resources or ResourceStore(Database(config.data_root))
        self.skills = skills or SkillIndex(self.resources)
        self.playbooks = playbooks or PlaybookIndex(self.resources, self.skills)
        self.events = EventLog(self.resources, store.title_of)
        self.catalog = ResourceCatalog(self.resources, self.events, self.skills, self.playbooks)
        self.deliveries = DeliveryStore(self.resources, self.events)
        self.link = LinkHub(config, self.resources, self.events, self.deliveries)
        self._name_untitled_agents()
        self.stream_slots = threading.BoundedSemaphore(self.SERVER_STREAMS_MAX)
        self.is_stopping = False
        super().__init__(
            (config.host, config.port),
            RoostRequestHandler,
        )
        if config.is_tls_enabled():
            self._wrap_tls()

    def _name_untitled_agents(self) -> None:
        for agent in self.resources.query(ResourceQuery(kind=ResourceKinds.AGENT.name, limit=ResourceQuery.QUERY_MAX_LIMIT)):
            if agent.map_attributes.get("title"):
                continue
            title = self.store.title_of(agent.id)
            if title:
                self.events.rename(agent.id, title)

    def handle_error(self, request: object, client_address: tuple[str, int]) -> None:
        """Log a client that dropped its connection in one line, and anything else in full.

        Args:
            request: the connection the failure happened on
            client_address: the client's address and port
        """
        error = sys.exc_info()[1]
        if isinstance(error, (ConnectionError, TimeoutError, ssl.SSLError)):
            sys.stderr.write(f"roost {client_address[0]} dropped the connection: {error}\n")
            return
        super().handle_error(request, client_address)

    def shutdown(self) -> None:
        """Stop serving, ending the event streams and the link too."""
        self.is_stopping = True
        self.link.shutdown()
        super().shutdown()

    def bound_port(self) -> int:
        """Report the port the server actually bound.

        Returns:
            the listening port, which differs from the configured one when the
            configuration asked for port zero
        """
        return int(self.socket.getsockname()[1])

    def _wrap_tls(self) -> None:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(
            certfile=str(self.config.tls_cert),
            keyfile=str(self.config.tls_key),
        )
        self.socket = context.wrap_socket(
            self.socket,
            server_side=True,
            do_handshake_on_connect=False,
        )
