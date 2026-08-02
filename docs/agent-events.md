# Hoshi Agent Event Protocol

Hoshi accepts small, versioned coding-agent events from two local-first
transports:

1. OSC frames received through an authenticated terminal session.
2. An optional bearer-token-protected, self-hosted HTTPS event feed.

Neither transport requires an account or allows an event to execute a shell
command.

## Event envelope

```json
{
  "version": 1,
  "id": "B364C791-9E0A-42F4-BAB7-99E493969EC6",
  "kind": "approval_requested",
  "title": "Agent needs approval",
  "message": "Review the proposed changes before continuing",
  "timestamp": "2026-08-01T21:00:00Z",
  "hostname": "agents.example.com",
  "tmuxSession": "coding-agents"
}
```

Required fields are `version`, `id`, `kind`, and `title`. Supported kinds are
`completed`, `needs_attention`, and `approval_requested`. Optional routing
fields are `hostname`, `tmuxSession`, `serverID`, and `sessionID`.

For terminal-originated events, Hoshi replaces all claimed server and session
identifiers with the authenticated connection that actually delivered the
bytes. Companion events are attached to a session only when their routing
fields identify exactly one active session.

Titles are limited to 512 UTF-8 bytes, messages to 4,096 bytes, hostnames to
255 bytes, and tmux session names to 256 bytes. Visible routing metadata cannot
contain control characters.

## Direct terminal framing

Encode the JSON envelope using standard Base64 and wrap it in this OSC frame:

```text
ESC ] 777 ; hoshi ; BASE64_JSON BEL
```

`ESC \\` is also accepted as the terminator. Frames may be split across
arbitrary terminal-output chunks. Valid frames are removed before bytes reach
the terminal renderer. Unsupported or malformed frames are passed through
unchanged, and oversized unterminated frames are never buffered indefinitely.

Use the included helper:

```bash
python3 scripts/hoshi-agent-companion.py emit completed \
  --title "Agent finished" \
  --message "All checks passed"
```

tmux and Mosh may consume OSC frames before they reach the mobile terminal. Use
the companion feed when an agent runs behind either transport.

## Companion HTTP feed

The companion provides one authenticated endpoint:

```http
GET /events?after=42 HTTP/1.1
Authorization: Bearer YOUR_TOKEN
Accept: application/json
```

```json
{
  "version": 1,
  "events": [],
  "nextCursor": "42"
}
```

Post an event to the same endpoint:

```http
POST /events HTTP/1.1
Authorization: Bearer YOUR_TOKEN
Content-Type: application/json
```

Duplicate event IDs are idempotent. Responses include no more than 100 events;
Hoshi rejects feeds larger than 256 KiB. The bundled companion keeps its most
recent 5,000 events in a private SQLite database.

Remote endpoints must use HTTPS. Plain HTTP is accepted only for `localhost`,
`127.0.0.1`, or `::1`. HTTP redirects are rejected so bearer tokens cannot be
forwarded to another origin. The iOS app stores companion tokens in Keychain
with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

The bundled daemon binds to loopback by default and refuses a remote bind
without explicit `--allow-remote-bind`. Expose it through a trusted HTTPS
reverse proxy when the phone must reach it over a network.

## Notifications and privacy

Notifications are opt-in. Tapping one opens the associated session or server
through a registered `hoshi://` URL. When app locking is enabled, lock-screen
notifications omit agent titles, server names, and message contents.

Approval notifications never contain executable actions. Their only actions
are opening the relevant terminal and marking the event as read.

Live Activities are independently opt-in under **Settings → Coding Agents →
Agent Monitoring**. They follow authenticated active sessions and display
only an agent status, unread attention count, and elapsed time on the Lock
Screen or Dynamic Island. Server and tmux session names are hidden by default;
the optional server-name setting is always overridden while Hoshi app lock is
enabled. Event titles, messages, terminal contents, credentials, and remote
commands are never included in Live Activity attributes or state. Tapping an
activity only opens its associated session through an existing `hoshi://`
deep link. Closing a session or disabling Live Activities removes its activity
immediately.

Companion polling runs while Hoshi is active. iOS can suspend application
networking in the background, so this protocol does not provide always-on
remote push notifications or cloud-backed Live Activity updates.
