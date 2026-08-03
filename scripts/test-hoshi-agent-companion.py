#!/usr/bin/env python3
"""Real HTTP and CLI integration coverage for the self-hosted Hoshi companion."""

from __future__ import annotations

import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen
import uuid


SCRIPT = Path(__file__).with_name("hoshi-agent-companion.py")


class HoshiCompanionIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.directory = tempfile.TemporaryDirectory(prefix="hoshi-agent-companion-")
        cls.token = "test-" + "a" * 32
        cls.environment = dict(
            os.environ,
            HOSHI_AGENT_TOKEN=cls.token,
            HOSHI_AGENT_HOSTNAME="test-agent.example.com",
        )
        cls.process = subprocess.Popen(
            [
                "python3",
                str(SCRIPT),
                "serve",
                "--port",
                "0",
                "--database",
                str(Path(cls.directory.name) / "events.sqlite3"),
            ],
            env=cls.environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        assert cls.process.stdout is not None
        line = cls.process.stdout.readline().strip()
        if "http://" not in line:
            cls.process.terminate()
            raise RuntimeError(f"Companion failed to start: {line}")
        cls.endpoint = line.split(" on ", maxsplit=1)[1]

    @classmethod
    def tearDownClass(cls) -> None:
        cls.process.terminate()
        try:
            cls.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            cls.process.kill()
            cls.process.wait(timeout=5)
        if cls.process.stdout is not None:
            cls.process.stdout.close()
        if cls.process.stderr is not None:
            cls.process.stderr.close()
        cls.directory.cleanup()

    def request(
        self,
        method: str,
        payload: dict[str, object] | None = None,
        *,
        token: str | None = None,
        suffix: str = "",
    ) -> tuple[int, dict[str, object]]:
        body = None if payload is None else json.dumps(payload).encode()
        request = Request(
            self.endpoint + suffix,
            data=body,
            method=method,
            headers={
                "Authorization": f"Bearer {self.token if token is None else token}",
                "Content-Type": "application/json",
            },
        )
        with urlopen(request, timeout=5) as response:
            return response.status, json.loads(response.read())

    def event(self, title: str = "Agent finished") -> dict[str, object]:
        return {
            "version": 1,
            "id": str(uuid.uuid4()),
            "kind": "completed",
            "title": title,
            "hostname": "agents.example.com",
        }

    def test_unauthenticated_requests_are_rejected(self) -> None:
        with self.assertRaises(HTTPError) as error:
            self.request("GET", token="wrong")
        self.assertEqual(error.exception.code, 401)

    def test_posted_events_round_trip_through_authenticated_feed(self) -> None:
        _, initial = self.request("GET")
        cursor = initial["nextCursor"]
        event = self.event("Round-trip agent event")

        status, accepted = self.request("POST", event)
        _, batch = self.request("GET", suffix=f"?after={cursor}")

        self.assertEqual(status, 201)
        self.assertTrue(accepted["accepted"])
        self.assertEqual(batch["events"][0]["title"], "Round-trip agent event")
        self.assertEqual(batch["version"], 1)

    def test_duplicate_event_ids_are_idempotent(self) -> None:
        event = self.event("Duplicate event")

        first_status, _ = self.request("POST", event)
        second_status, second = self.request("POST", event)

        self.assertEqual(first_status, 201)
        self.assertEqual(second_status, 200)
        self.assertTrue(second["duplicate"])

    def test_invalid_event_versions_are_rejected(self) -> None:
        event = self.event()
        event["version"] = 999

        with self.assertRaises(HTTPError) as error:
            self.request("POST", event)
        self.assertEqual(error.exception.code, 400)

    def test_invalid_timestamps_and_control_characters_are_rejected(self) -> None:
        invalid_timestamp = self.event()
        invalid_timestamp["timestamp"] = "not-a-date"
        with self.assertRaises(HTTPError) as timestamp_error:
            self.request("POST", invalid_timestamp)
        self.assertEqual(timestamp_error.exception.code, 400)

        for control in ("\u001b", "\u007f", "\u0085"):
            with self.subTest(control=repr(control)):
                invalid_title = self.event()
                invalid_title["title"] = f"Agent{control} title"
                with self.assertRaises(HTTPError) as title_error:
                    self.request("POST", invalid_title)
                self.assertEqual(title_error.exception.code, 400)

        for field in ("hostname", "tmuxSession"):
            with self.subTest(field=field):
                invalid_routing = self.event()
                invalid_routing[field] = "routing\u007fmetadata"
                with self.assertRaises(HTTPError) as routing_error:
                    self.request("POST", invalid_routing)
                self.assertEqual(routing_error.exception.code, 400)

    def test_invalid_event_cursors_are_rejected(self) -> None:
        with self.assertRaises(HTTPError) as error:
            self.request("GET", suffix="?after=not-a-number")
        self.assertEqual(error.exception.code, 400)

    def test_cli_emits_a_compatible_terminal_osc_event(self) -> None:
        result = subprocess.run(
            ["python3", str(SCRIPT), "emit", "needs_attention", "--title", "Review requested"],
            check=True,
            capture_output=True,
            env=self.environment,
        )

        prefix = b"\x1b]777;hoshi;"
        self.assertTrue(result.stdout.startswith(prefix))
        self.assertTrue(result.stdout.endswith(b"\x07"))
        payload = json.loads(base64.b64decode(result.stdout[len(prefix) : -1]))
        self.assertEqual(payload["kind"], "needs_attention")
        self.assertEqual(payload["title"], "Review requested")
        self.assertEqual(payload["hostname"], "test-agent.example.com")

    def test_cli_posts_events_to_the_real_companion(self) -> None:
        _, initial = self.request("GET")
        environment = dict(self.environment, HOSHI_AGENT_COMPANION_URL=self.endpoint)

        subprocess.run(
            [
                "python3",
                str(SCRIPT),
                "emit",
                "approval_requested",
                "--title",
                "Approval needed",
                "--tmux-session",
                "coding-agents",
            ],
            env=environment,
            check=True,
            capture_output=True,
        )

        _, batch = self.request("GET", suffix=f"?after={initial['nextCursor']}")
        self.assertEqual(batch["events"][0]["kind"], "approval_requested")
        self.assertEqual(batch["events"][0]["tmuxSession"], "coding-agents")

    def test_remote_plain_http_endpoint_is_rejected_before_network_access(self) -> None:
        environment = dict(self.environment, HOSHI_AGENT_COMPANION_URL="http://remote.example.com/events")
        result = subprocess.run(
            ["python3", str(SCRIPT), "emit", "completed", "--title", "Done"],
            env=environment,
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HTTPS", result.stderr)

    def test_cli_rejects_redirects_without_forwarding_the_bearer_token(self) -> None:
        captured_authorizations: list[str] = []

        class RedirectingHandler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:
                self.send_response(302)
                self.send_header("Location", f"http://localhost:{self.server.server_port}/captured")
                self.end_headers()

            def do_GET(self) -> None:
                captured_authorizations.append(self.headers.get("Authorization", ""))
                self.send_response(200)
                self.end_headers()

            def log_message(self, format: str, *args: object) -> None:
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), RedirectingHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        try:
            environment = dict(
                self.environment,
                HOSHI_AGENT_COMPANION_URL=f"http://127.0.0.1:{server.server_port}/events",
            )
            result = subprocess.run(
                ["python3", str(SCRIPT), "emit", "completed", "--title", "Done"],
                env=environment,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("302", result.stderr)
            self.assertEqual(captured_authorizations, [])
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

    def test_remote_bind_requires_explicit_opt_in(self) -> None:
        result = subprocess.run(
            ["python3", str(SCRIPT), "serve", "--bind", "0.0.0.0"],
            env=self.environment,
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing a non-loopback", result.stderr)


if __name__ == "__main__":
    unittest.main()
