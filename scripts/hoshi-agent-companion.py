#!/usr/bin/env python3
"""Small, account-free event companion for Hoshi coding-agent notifications."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hmac
import ipaddress
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import sys
import unicodedata
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener
import uuid


PROTOCOL_VERSION = 1
MAX_REQUEST_BYTES = 32_768
MAX_BATCH_EVENTS = 100
MAX_STORED_EVENTS = 5_000
EVENT_KINDS = {"completed", "needs_attention", "approval_requested"}
DEFAULT_DATABASE = Path.home() / ".local" / "state" / "hoshi" / "agent-events.sqlite3"


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def token_from_environment() -> str:
    token = os.environ.get("HOSHI_AGENT_TOKEN", "").strip()
    if len(token) < 16 or any(ord(character) < 0x21 or ord(character) > 0x7E for character in token):
        fail("set HOSHI_AGENT_TOKEN to a random token containing at least 16 characters")
    return token


def is_loopback_host(value: str) -> bool:
    if value.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(value).is_loopback
    except ValueError:
        return False


def validate_endpoint(endpoint: str) -> str:
    parsed = urlparse(endpoint)
    if not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        fail("the companion endpoint must be a valid URL without embedded credentials")
    if parsed.scheme == "https":
        return endpoint
    if parsed.scheme == "http" and is_loopback_host(parsed.hostname):
        return endpoint
    fail("companion endpoints require HTTPS unless they use localhost")
    raise AssertionError("unreachable")


def contains_control_characters(value: str) -> bool:
    return any(unicodedata.category(character) == "Cc" for character in value)


class EventStore:
    def __init__(self, database: Path) -> None:
        self.database = database.expanduser()
        self.database.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with self.connection() as connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS events (
                    cursor INTEGER PRIMARY KEY AUTOINCREMENT,
                    event_id TEXT NOT NULL UNIQUE,
                    payload TEXT NOT NULL
                )
                """
            )
        try:
            self.database.chmod(0o600)
        except OSError:
            pass

    def connection(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database, timeout=10)
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA busy_timeout=5000")
        return connection

    def append(self, event: dict[str, Any]) -> bool:
        with self.connection() as connection:
            cursor = connection.execute(
                "INSERT OR IGNORE INTO events (event_id, payload) VALUES (?, ?)",
                (event["id"], json.dumps(event, separators=(",", ":"))),
            )
            connection.execute(
                "DELETE FROM events WHERE cursor NOT IN (SELECT cursor FROM events ORDER BY cursor DESC LIMIT ?)",
                (MAX_STORED_EVENTS,),
            )
            return cursor.rowcount == 1

    def after(self, cursor: int) -> tuple[list[dict[str, Any]], str]:
        with self.connection() as connection:
            rows = connection.execute(
                "SELECT cursor, payload FROM events WHERE cursor > ? ORDER BY cursor LIMIT ?",
                (cursor, MAX_BATCH_EVENTS),
            ).fetchall()
        events = [json.loads(payload) for _, payload in rows]
        next_cursor = str(rows[-1][0] if rows else cursor)
        return events, next_cursor


def validate_event(event: Any) -> dict[str, Any]:
    if not isinstance(event, dict):
        raise ValueError("event must be a JSON object")
    if event.get("version") != PROTOCOL_VERSION:
        raise ValueError("unsupported event version")
    if event.get("kind") not in EVENT_KINDS:
        raise ValueError("unsupported event kind")

    try:
        event["id"] = str(uuid.UUID(str(event["id"]))).upper()
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError("event id must be a UUID") from error

    title = event.get("title")
    if not isinstance(title, str) or not title.strip() or len(title.encode()) > 512 or contains_control_characters(title):
        raise ValueError("event title must contain at most 512 UTF-8 bytes")
    message = event.get("message")
    if message is not None and (not isinstance(message, str) or len(message.encode()) > 4_096):
        raise ValueError("event message must contain at most 4,096 UTF-8 bytes")

    for key, maximum in (("hostname", 255), ("tmuxSession", 256)):
        value = event.get(key)
        if value is not None and (
            not isinstance(value, str)
            or len(value.encode()) > maximum
            or contains_control_characters(value)
        ):
            raise ValueError(f"{key} exceeds its size limit")

    timestamp = event.get("timestamp")
    if timestamp is not None:
        try:
            value = dt.datetime.fromisoformat(str(timestamp).replace("Z", "+00:00"))
            if value.tzinfo is None:
                raise ValueError
        except (TypeError, ValueError) as error:
            raise ValueError("timestamp must be an ISO-8601 instant with a timezone") from error

    for key in ("serverID", "sessionID"):
        value = event.get(key)
        if value is not None:
            try:
                event[key] = str(uuid.UUID(value)).upper()
            except (TypeError, ValueError) as error:
                raise ValueError(f"{key} must be a UUID") from error

    return event


class CompanionHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], store: EventStore, token: str) -> None:
        self.store = store
        self.token = token
        super().__init__(address, CompanionRequestHandler)


class CompanionRequestHandler(BaseHTTPRequestHandler):
    server: CompanionHTTPServer

    def do_GET(self) -> None:
        if not self.authorized():
            return
        parsed = urlparse(self.path)
        if parsed.path not in ("/events", "/events/"):
            self.send_json(404, {"error": "not found"})
            return

        try:
            cursor = int(parse_qs(parsed.query).get("after", ["0"])[0])
            if cursor < 0:
                raise ValueError
        except (TypeError, ValueError):
            self.send_json(400, {"error": "invalid event cursor"})
            return

        events, next_cursor = self.server.store.after(cursor)
        self.send_json(200, {"version": PROTOCOL_VERSION, "events": events, "nextCursor": next_cursor})

    def do_POST(self) -> None:
        if not self.authorized():
            return
        if urlparse(self.path).path not in ("/events", "/events/"):
            self.send_json(404, {"error": "not found"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_json(400, {"error": "invalid content length"})
            return
        if length <= 0 or length > MAX_REQUEST_BYTES:
            self.send_json(413, {"error": "event payload exceeds its size limit"})
            return

        try:
            payload = self.rfile.read(length)
            event = validate_event(json.loads(payload.decode("utf-8")))
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
            self.send_json(400, {"error": str(error)})
            return

        created = self.server.store.append(event)
        self.send_json(201 if created else 200, {"accepted": True, "duplicate": not created, "id": event["id"]})

    def authorized(self) -> bool:
        header = self.headers.get("Authorization", "")
        expected = f"Bearer {self.server.token}"
        if not hmac.compare_digest(header.encode(), expected.encode()):
            self.send_json(401, {"error": "unauthorized"})
            return False
        return True

    def send_json(self, status: int, payload: dict[str, Any]) -> None:
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format: str, *args: Any) -> None:
        sys.stderr.write(f"hoshi-companion: {format % args}\n")


def current_tmux_session() -> str | None:
    if not os.environ.get("TMUX"):
        return None
    try:
        result = subprocess.run(
            ["tmux", "display-message", "-p", "#{session_name}"],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    value = result.stdout.strip()
    return value if result.returncode == 0 and value else None


def make_event(args: argparse.Namespace) -> dict[str, Any]:
    event: dict[str, Any] = {
        "version": PROTOCOL_VERSION,
        "id": str(uuid.uuid4()).upper(),
        "kind": args.kind,
        "title": args.title,
        "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "hostname": args.hostname or os.environ.get("HOSHI_AGENT_HOSTNAME") or socket.getfqdn(),
    }
    if args.message:
        event["message"] = args.message
    tmux_session = args.tmux_session or current_tmux_session()
    if tmux_session:
        event["tmuxSession"] = tmux_session
    if args.server_id:
        event["serverID"] = args.server_id
    if args.session_id:
        event["sessionID"] = args.session_id
    return validate_event(event)


def emit_terminal_event(event: dict[str, Any]) -> None:
    encoded = base64.b64encode(json.dumps(event, separators=(",", ":")).encode("utf-8"))
    sys.stdout.buffer.write(b"\x1b]777;hoshi;" + encoded + b"\x07")
    sys.stdout.buffer.flush()


class RefuseRedirectHandler(HTTPRedirectHandler):
    def redirect_request(
        self,
        request: Request,
        response: Any,
        code: int,
        message: str,
        headers: Any,
        new_url: str,
    ) -> None:
        return None


def post_event(endpoint: str, token: str, event: dict[str, Any]) -> None:
    endpoint = validate_endpoint(endpoint)
    data = json.dumps(event, separators=(",", ":")).encode("utf-8")
    request = Request(
        endpoint,
        data=data,
        method="POST",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    try:
        with build_opener(RefuseRedirectHandler()).open(request, timeout=10) as response:
            response.read()
    except HTTPError as error:
        fail(f"companion rejected the event with HTTP status {error.code}")
    except URLError as error:
        fail(f"unable to reach the companion: {error.reason}")


def run_server(args: argparse.Namespace) -> None:
    token = token_from_environment()
    if not is_loopback_host(args.bind) and not args.allow_remote_bind:
        fail("refusing a non-loopback bind without --allow-remote-bind and a trusted HTTPS reverse proxy")

    store = EventStore(Path(args.database))
    server = CompanionHTTPServer((args.bind, args.port), store, token)
    host, port = server.server_address[:2]
    print(f"Hoshi companion listening on http://{host}:{port}/events", flush=True)
    try:
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def run_emit(args: argparse.Namespace) -> None:
    try:
        event = make_event(args)
    except ValueError as error:
        fail(str(error))

    endpoint = args.endpoint or os.environ.get("HOSHI_AGENT_COMPANION_URL")
    if endpoint:
        post_event(endpoint, token_from_environment(), event)

    if not endpoint or args.also_terminal:
        emit_terminal_event(event)


def parser() -> argparse.ArgumentParser:
    argument_parser = argparse.ArgumentParser(description=__doc__)
    commands = argument_parser.add_subparsers(dest="command", required=True)

    serve = commands.add_parser("serve", help="serve a local bearer-token-protected event feed")
    serve.add_argument("--bind", default="127.0.0.1")
    serve.add_argument("--port", default=8765, type=int)
    serve.add_argument("--database", default=str(DEFAULT_DATABASE))
    serve.add_argument("--allow-remote-bind", action="store_true")
    serve.set_defaults(handler=run_server)

    emit = commands.add_parser("emit", help="emit an agent event to a companion or SSH terminal")
    emit.add_argument("kind", choices=sorted(EVENT_KINDS))
    emit.add_argument("--title", required=True)
    emit.add_argument("--message")
    emit.add_argument("--hostname")
    emit.add_argument("--tmux-session")
    emit.add_argument("--server-id")
    emit.add_argument("--session-id")
    emit.add_argument("--endpoint")
    emit.add_argument("--also-terminal", action="store_true")
    emit.set_defaults(handler=run_emit)

    return argument_parser


def main() -> None:
    args = parser().parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
