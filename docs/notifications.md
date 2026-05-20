# Notifications — Linux backends

The Linux scripts call `notify "subject" "message" [priority]` from
[`scripts/linux/lib/notify.sh`](../scripts/linux/lib/notify.sh). Which backend handles
the call is chosen via `NOTIFY_BACKEND` in `/etc/dumb-scripts/config.env`. Any backend
failure falls back to syslog so notifications are never silently dropped.

On Unraid, notifications go through the WebUI's built-in `notify` script — this doc
doesn't apply there.

---

## `logger` (default)

Writes to syslog/journal with tag `dumb-scripts`. No external dependency, no rate
limits, easy to forward to anything that reads syslog (rsyslog, Loki, journald
forwarding, etc.).

```
NOTIFY_BACKEND=logger
```

Verify:

```bash
journalctl -t dumb-scripts -f
# Then trigger a notification, e.g. by running:
sudo systemctl start nzbdav-heartbeat.service
```

---

## `ntfy` — [ntfy.sh](https://ntfy.sh) topic

Push notifications to your phone / desktop / browser via a public or self-hosted ntfy
server. Free, no account required.

```
NOTIFY_BACKEND=ntfy
NTFY_URL=https://ntfy.sh/your-secret-topic-here
```

Use a long, unguessable topic name (it acts as the password). For self-hosted, point
`NTFY_URL` at your server.

Verify:

```bash
curl -fsS -d "test" -H "Title: dumb-scripts test" "$NTFY_URL"
```

---

## `apprise` — [Apprise](https://github.com/caronc/apprise) (any provider)

Fan-out to 80+ destinations (Discord, Telegram, Slack, Matrix, Pushover, email, etc.)
via the Apprise CLI.

Install once: `pipx install apprise` or `pip install --user apprise`.

```
NOTIFY_BACKEND=apprise
APPRISE_URLS=discord://avatar_id/webhook_token,tgram://bot_token/chat_id
```

(Comma-separated is fine — Apprise parses the list.)

Verify:

```bash
apprise -t "dumb-scripts test" -b "hello" -- "$APPRISE_URLS"
```

---

## `discord` — Discord webhook

If you only need Discord, this skips the Apprise dependency.

```
NOTIFY_BACKEND=discord
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/<channel_id>/<token>
```

Get the webhook URL: server settings → Integrations → Webhooks → New Webhook → copy
URL.

Verify:

```bash
curl -fsS -H "Content-Type: application/json" \
  -d '{"content":"**dumb-scripts test**"}' \
  "$DISCORD_WEBHOOK_URL"
```

---

## Priority mapping

The scripts emit two priorities: `normal` and `alert`. Each backend translates:

| Script priority | logger / syslog | ntfy priority | Discord prefix | Apprise type |
|---|---|---|---|---|
| `normal` | `user.info` | 3 | `[normal]` | (default) |
| `alert` | `user.warning` | 4 | `[alert]` | (passed verbatim) |

---

## Adding a new backend

The dispatcher is a single `case "$backend"` block in `scripts/linux/lib/notify.sh`.
Add a new arm, do the actual send (with `curl --max-time` for HTTP backends), and
`return 0` on success. The fallback to `logger` at the bottom catches every failure
automatically.
