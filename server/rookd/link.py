import json
import secrets
import ssl
import sys
import threading
from http import HTTPStatus
from websockets.exceptions import ConnectionClosed
from websockets.http11 import Request, Response
from websockets.sync.server import Server, ServerConnection, serve
from rookd import ROOKD_VERSION
from rookd.config import ServerConfig
from rookd.errors import RookdError, ValidationError
from rookd.events import EventLog, EventVerbs
from rookd.messages import Delivery, DeliveryStore
from rookd.resources import ResourceKinds, ResourceRef, ResourceStore


class LinkPeer:
    """One client holding the link open: a rook, which runs agents, or a desktop, which watches them."""

    ROLE_ROOK = "rook"
    ROLE_DESKTOP = "desktop"
    SET_ROLES = frozenset({ROLE_ROOK, ROLE_DESKTOP})

    def __init__(
        self,
        connection: ServerConnection,
        role: str,
        rook_name: str | None,
        subscribed_after: int | None,
    ) -> None:
        self.connection = connection
        self.role = role
        self.rook_name = rook_name
        self.subscribed_after = subscribed_after
        self.is_closed = False
        self._send_lock = threading.Lock()

    def send(self, map_message: dict[str, object]) -> None:
        """Send one message to the client.

        Raises:
            ConnectionClosed: if the client has gone
        """
        with self._send_lock:
            self.connection.send(json.dumps(map_message))

    def close(self, code: int, reason: str) -> None:
        """Close the client's connection."""
        self.connection.close(code=code, reason=reason)


class LinkHub:
    """The live link: one WebSocket per rook and per desktop, held open.

    Desktops subscribe to the event log and send prompts; rooks send their events, take the deliveries
    for the agents they run, and report what became of each. The hub knows which rooks are online and
    hands a delivery to its rook at once, or when the rook next connects. The protocol is in
    server/API.md.
    """

    LINK_PATH = "/v1/link"
    LINK_BEARER_PREFIX = "Bearer "
    LINK_HELLO_TIMEOUT_SECONDS = 10
    LINK_EVENT_WAIT_SECONDS = 15
    LINK_CLOSE_REPLACED = 4000
    LINK_CLOSE_BAD_HELLO = 4001
    LINK_MAX_MESSAGE_BYTES = 4 * 1024 * 1024

    def __init__(
        self,
        config: ServerConfig,
        resources: ResourceStore,
        events: EventLog,
        deliveries: DeliveryStore,
    ) -> None:
        self._config = config
        self._resources = resources
        self._events = events
        self._deliveries = deliveries
        self._lock = threading.Lock()
        self._map_rooks: dict[str, LinkPeer] = {}
        self._is_stopping = False
        self._server: Server | None = None

    def listen(self) -> None:
        """Bind the link's port, with every rook offline until it connects; `serve_forever` then serves it."""
        self._mark_rooks_offline()
        context = None
        if self._config.is_tls_enabled():
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(
                certfile=str(self._config.tls_cert),
                keyfile=str(self._config.tls_key),
            )
        self._server = serve(
            self._handle,
            host=self._config.host,
            port=self._config.effective_link_port(),
            ssl=context,
            process_request=self._check_request,
            max_size=self.LINK_MAX_MESSAGE_BYTES,
        )

    def serve_forever(self) -> None:
        """Serve the link until `shutdown`."""
        if self._server is None:
            self.listen()
        if self._server is not None:
            self._server.serve_forever()

    def shutdown(self) -> None:
        """Stop serving and close every connection."""
        self._is_stopping = True
        self._events.wake()
        if self._server is not None:
            self._server.shutdown()

    def bound_port(self) -> int | None:
        """The port the link listens on, or None before `listen`."""
        if self._server is None:
            return None
        return int(self._server.socket.getsockname()[1])

    def online_rooks(self) -> list[str]:
        """The rooks holding the link open now."""
        with self._lock:
            return sorted(self._map_rooks)

    def send_to_agent(self, sender: ResourceRef, agent_id: str, text: str) -> Delivery:
        """Hold text for an agent and hand it to the agent's rook if that rook is online.

        Args:
            sender: the person or agent sending it
            agent_id: the agent
            text: what to tell it

        Returns:
            the delivery

        Raises:
            ValidationError: if the text or the agent cannot take a delivery
            NotFoundError: if there is no such agent
        """
        delivery = self._deliveries.create(sender, agent_id, text)
        with self._lock:
            peer = self._map_rooks.get(delivery.rook_name)
        if peer is not None:
            self._hand_over(peer, delivery)
        return delivery

    def _check_request(self, connection: ServerConnection, request: Request) -> Response | None:
        if request.path.split("?")[0] != self.LINK_PATH:
            return connection.respond(HTTPStatus.NOT_FOUND, "no such route\n")
        header = request.headers.get("Authorization", "")
        offered = header[len(self.LINK_BEARER_PREFIX):] if header.startswith(self.LINK_BEARER_PREFIX) else ""
        if not offered or not secrets.compare_digest(offered, self._config.token):
            return connection.respond(HTTPStatus.UNAUTHORIZED, "bearer token not accepted\n")
        return None

    def _handle(self, connection: ServerConnection) -> None:
        try:
            peer = self._greet(connection)
        except (ValidationError, TimeoutError, ValueError) as err:
            connection.close(code=self.LINK_CLOSE_BAD_HELLO, reason=str(err)[:120])
            return
        except ConnectionClosed:
            return
        if peer.subscribed_after is not None:
            threading.Thread(target=self._forward_events, args=(peer,), daemon=True).start()
        if peer.role == LinkPeer.ROLE_ROOK and peer.rook_name:
            for delivery in self._deliveries.open_for_rook(peer.rook_name):
                self._hand_over(peer, delivery)
        try:
            for raw in connection:
                self._answer(peer, raw)
        except ConnectionClosed:
            pass
        finally:
            peer.is_closed = True
            self._forget(peer)

    def _greet(self, connection: ServerConnection) -> LinkPeer:
        map_hello = json.loads(connection.recv(timeout=self.LINK_HELLO_TIMEOUT_SECONDS))
        if not isinstance(map_hello, dict) or map_hello.get("type") != "hello":
            raise ValidationError("the first message must be a hello")
        role = str(map_hello.get("role") or "")
        if role not in LinkPeer.SET_ROLES:
            raise ValidationError(f"unknown role: {role!r}")
        after = map_hello.get("after")
        if after is not None and not isinstance(after, int):
            raise ValidationError("after must be an event sequence number")
        rook_name = None
        if role == LinkPeer.ROLE_ROOK:
            rook_name = ResourceRef.of(ResourceKinds.ROOK.name, str(map_hello.get("rook") or "")).id
        peer = LinkPeer(connection, role, rook_name, after)
        if rook_name:
            with self._lock:
                previous = self._map_rooks.get(rook_name)
                self._map_rooks[rook_name] = peer
            if previous is not None:
                previous.close(self.LINK_CLOSE_REPLACED, "another connection took over this rook")
            self._events.record([{
                "actor": {"kind": ResourceKinds.ROOK.name, "id": rook_name},
                "verb": EventVerbs.CONNECTED,
                "detail": {
                    "machine": map_hello.get("machine") if isinstance(map_hello.get("machine"), dict) else {},
                    "accepts_prompts": map_hello.get("accepts_prompts") is not False,
                },
            }])
        peer.send({
            "type": "welcome",
            "version": ROOKD_VERSION,
            "last_seq": self._last_seq(),
        })
        return peer

    def _answer(self, peer: LinkPeer, raw: str | bytes) -> None:
        ref = None
        try:
            map_message = json.loads(raw)
            if not isinstance(map_message, dict):
                raise ValidationError("a message must be an object")
            ref = map_message.get("ref")
            kind = map_message.get("type")
            if kind == "send":
                delivery = self.send_to_agent(
                    self._sender_of(peer, map_message.get("as")),
                    str(map_message.get("to") or ""),
                    str(map_message.get("text") or ""),
                )
                peer.send({"type": "sent", "ref": ref, "delivery": delivery.as_payload()})
            elif kind == "events" and peer.role == LinkPeer.ROLE_ROOK:
                list_events = self._events.record(map_message.get("events") or [])
                peer.send({"type": "recorded", "ref": ref, "count": len(list_events)})
            elif kind == "delivery" and peer.rook_name:
                self._deliveries.report(
                    peer.rook_name,
                    str(map_message.get("id") or ""),
                    str(map_message.get("status") or ""),
                    str(map_message.get("reason") or ""),
                )
            else:
                raise ValidationError(f"a {peer.role} cannot send {kind!r}")
        except ValueError as err:
            peer.send({"type": "error", "ref": ref, "status": 400, "message": f"not JSON: {err}"})
        except RookdError as err:
            peer.send({"type": "error", "ref": ref, "status": err.ERROR_HTTP_STATUS, "message": err.message})

    def _sender_of(self, peer: LinkPeer, map_as: object) -> ResourceRef:
        if peer.role == LinkPeer.ROLE_DESKTOP or map_as is None:
            return EventLog.EVENT_PERSON
        agent_ref = ResourceRef.from_payload(map_as)
        if agent_ref.kind != ResourceKinds.AGENT.name:
            raise ValidationError("a rook sends as one of its agents")
        agent = self._resources.get(agent_ref)
        if agent.map_attributes.get("rook_name") != peer.rook_name:
            raise ValidationError(f"agent {agent.name} does not run under rook {peer.rook_name}")
        return agent_ref

    def _hand_over(self, peer: LinkPeer, delivery: Delivery) -> None:
        try:
            peer.send({"type": "deliver", "delivery": delivery.as_payload()})
        except ConnectionClosed:
            return
        self._deliveries.mark_sent(delivery.id)

    def _forward_events(self, peer: LinkPeer) -> None:
        seq = peer.subscribed_after or 0
        try:
            while not self._is_stopping and not peer.is_closed:
                for event in self._events.wait_after(seq, self.LINK_EVENT_WAIT_SECONDS):
                    peer.send({"type": "event", "event": event.as_payload()})
                    seq = event.seq
        except ConnectionClosed:
            return

    def _forget(self, peer: LinkPeer) -> None:
        if not peer.rook_name:
            return
        with self._lock:
            if self._map_rooks.get(peer.rook_name) is not peer:
                return
            del self._map_rooks[peer.rook_name]
        try:
            self._events.record([{
                "actor": {"kind": ResourceKinds.ROOK.name, "id": peer.rook_name},
                "verb": EventVerbs.DISCONNECTED,
            }])
        except RookdError as err:
            sys.stderr.write(f"rookd could not log rook {peer.rook_name} leaving: {err.message}\n")

    def _mark_rooks_offline(self) -> None:
        with self._resources.database.transaction() as connection:
            list_rows = connection.execute(
                "SELECT * FROM resources WHERE kind = ?",
                (ResourceKinds.ROOK.name,),
            ).fetchall()
            for row in list_rows:
                rook = ResourceStore.resource_of(row)
                if rook.map_attributes.get("online"):
                    rook.map_attributes["online"] = False
                    self._resources.put(rook, connection)

    def _last_seq(self) -> int:
        list_latest = self._events.latest(1)
        return list_latest[0].seq if list_latest else 0
