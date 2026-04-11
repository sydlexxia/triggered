# triggered

A lightweight, real-time visual alert system built with Perl + Mojolicious.
An external system (CI pipeline, monitoring tool, cron job, etc.) fires a webhook — every connected browser instantly flips to a red **ALERT** screen, then auto-resets to green after a configurable countdown.
A companion React dashboard provides a live status panel, real-time log viewer, alert history, and camera snapshot viewer.

```
┌─────────────────────────────────────────────────────┐
│  triggered.pl          dashboard.pl                 │
│  :3000                 :3001                        │
│                                                     │
│  POST /webhook  ──►  SSE /events  ──►  browser      │
│  POST /reset          /api/log-stream               │
│  POST /snapshot       /api/snapshots (proxy)        │
│  GET  /events         GET /                         │
│  GET  /api/history                                  │
└─────────────────────────────────────────────────────┘
```

---

## Files

| File | Description |
|---|---|
| `triggered.pl` | Alert server — webhook receiver, SSE broadcaster, auto-reset timer, snapshot cache, alert history |
| `dashboard.pl` | Monitoring dashboard — React UI, live log tail over SSE, snapshot proxy |
| `trigctl` | Control script — start, stop, status, logs, and more |
| `cpanfile` | Perl dependency declaration (`Mojolicious >= 9.0`) |

---

## Requirements

- Perl >= 5.20
- [Mojolicious](https://mojolicious.org) >= 9.0

```bash
# Install Mojolicious (via cpanminus)
cpanm --installdeps .

# Or install directly
cpanm Mojolicious
```

---

## Quick Start

### 1. Configure

Copy your settings into `.trigctl.env` in the project directory (it's gitignored):

```
WEBHOOK_TOKEN=your_secret_here
LISTEN_HOST=0.0.0.0
RESET_DELAY=60
```

### 2. (Optional) Add trigctl to PATH

```bash
ln -sf /path/to/visual_alert/trigctl ~/bin/trigctl
```

### 3. Start

```bash
trigctl start
```

- Alert page: **http://127.0.0.1:3000**
- Dashboard: **http://127.0.0.1:3001**

```bash
trigctl status    # process state, HTTP health, connected client count
trigctl stop      # graceful shutdown of both servers
```

---

## trigctl

`trigctl` manages both servers with a single command. It reads defaults from `.trigctl.env` in the project directory; any `KEY=VALUE` argument on the command line overrides the file.

### Commands

| Command | Description |
|---|---|
| `trigctl start [--prod\|--dev]` | Start `triggered.pl` and `dashboard.pl` |
| `trigctl stop` | Stop both servers |
| `trigctl restart [--prod\|--dev]` | Stop then start |
| `trigctl status` | Process state, HTTP health, connected client count, alert state |
| `trigctl logs [triggered\|dashboard]` | Tail log output (default: both) |
| `trigctl reload` | Zero-downtime hypnotoad reload — prod mode only |
| `trigctl trigger ["Camera Name"]` | Fire a test webhook using the configured token |
| `trigctl reset` | Clear the alert via API |
| `trigctl setup` | First-time dependency install |
| `trigctl doctor` | Pre-flight checks — Perl version, deps, port availability, config |
| `trigctl help` | Full usage reference |

### Modes

| Flag | Server | Use case |
|---|---|---|
| `--dev` *(default)* | `perl daemon` | Development — single process, auto-reloads on source changes |
| `--prod` | `hypnotoad` | Production — prefork, graceful restarts, zero-downtime reload |

### Config file — `.trigctl.env`

Variables in this file are loaded as defaults on every invocation. The file is gitignored to keep secrets out of version control.

```bash
# .trigctl.env
WEBHOOK_TOKEN=your_secret_here
LISTEN_HOST=0.0.0.0
PORT=3000
DASHBOARD_PORT=3001
RESET_DELAY=60
LOG_FILE=./triggered.log
TRIGGERED_LOG=./triggered.log
DASHBOARD_LOG=./dashboard.log
# ALERT_SOUND=/path/to/alert.mp3
# DEBUG=1
```

CLI `KEY=VALUE` args always take precedence:

```bash
trigctl start RESET_DELAY=30 LISTEN_HOST=0.0.0.0
```

### Examples

```bash
# Start in dev mode (reads token etc. from .trigctl.env)
trigctl start

# Start in production mode
trigctl start --prod

# Check what's running
trigctl status

# Fire a test alert
trigctl trigger "Front Door"

# Clear it manually
trigctl reset

# Watch the alert server log
trigctl logs triggered

# Zero-downtime reload after editing a Perl script (prod only)
trigctl reload

# Enable verbose debug logging
DEBUG=1 trigctl start
```

---

## Configuration

All configuration is done via environment variables — no file editing required.
The easiest way to manage them is via `.trigctl.env` (see above).

### triggered.pl

| Variable | Default | Description |
|---|---|---|
| `PORT` | `3000` | Listen port |
| `LISTEN_HOST` | `127.0.0.1` | Bind address |
| `RESET_DELAY` | `60` | Seconds before auto-reset to green |
| `WEBHOOK_TOKEN` | *(unset)* | Bearer token required on `/webhook`, `/reset`, and `/snapshot`. If unset, endpoints are open — a warning is printed at startup |
| `LOG_FILE` | `./triggered.log` | Path to write log output |
| `ALERT_SOUND` | *(unset)* | Path to an audio file (`.mp3`, `.wav`, `.ogg`, `.m4a`) played in the browser when an alert fires. Served to the browser at `/alert-sound`. If unset, the alert is silent |
| `CAMERA_ALLOW` | *(unset)* | Comma-separated list of camera names. When set, only cameras in this list trigger an alert; all others are suppressed |
| `CAMERA_IGNORE` | *(unset)* | Comma-separated list of camera names to always suppress (logged but never trigger an alert) |
| `QUIET_START` | *(unset)* | Start of quiet hours in 24h `HH:MM` format (e.g. `22:00`). Alerts during quiet hours show an amber **QUIET** state instead of red |
| `QUIET_END` | *(unset)* | End of quiet hours in 24h `HH:MM` format (e.g. `07:00`). Wraps midnight correctly |
| `NOTIFY_URL` | *(unset)* | Push notification endpoint. Supports ntfy.sh, Slack, Discord, or any generic HTTP webhook |
| `NOTIFY_ON_RESET` | `0` | Set `1` to also send a push notification when the alert clears |
| `SNAPSHOT_TTL` | `300` | Seconds before a stored camera snapshot is considered expired |
| `SNAPSHOT_MAX_BYTES` | `2097152` | Maximum snapshot upload size in bytes (default 2 MB) |
| `DEBUG` | `0` | Set `1` to enable verbose debug logging. Debug lines appear in cyan in the dashboard log viewer |

### dashboard.pl

| Variable | Default | Description |
|---|---|---|
| `DASHBOARD_PORT` | `3001` | Listen port |
| `LISTEN_HOST` | `127.0.0.1` | Bind address |
| `TRIGGERED_URL` | `http://127.0.0.1:3000` | Base URL of triggered.pl (used by the React frontend to connect to `/events`) |
| `TRIGGERED_LOG` | `./triggered.log` | Path to the triggered.pl log file to tail |
| `WEBHOOK_TOKEN` | *(unset)* | Same token as triggered.pl |
| `DEBUG` | `0` | Set `1` to enable verbose debug logging |

---

## API Reference

### `POST /webhook`
Triggers an alert — sets state to **red** and starts the auto-reset countdown.
Accepts an optional body with a `camera` field in JSON, `camera:Name` plain-text (Blue Iris default), or `?camera=Name` URL parameter.

```bash
# Basic trigger
curl -X POST \
  -H "Authorization: Bearer secret" \
  http://127.0.0.1:3000/webhook

# With camera name (JSON body)
curl -X POST \
  -H "Authorization: Bearer secret" \
  -H "Content-Type: application/json" \
  -d '{"camera":"Front Door"}' \
  http://127.0.0.1:3000/webhook

# Blue Iris plain-text body format
curl -X POST \
  -H "Authorization: Bearer secret" \
  -d 'camera:Front Door' \
  http://127.0.0.1:3000/webhook

# Shortcut via trigctl (uses token from .trigctl.env)
trigctl trigger "Front Door"
```

**Response:**
```json
{ "status": "ok", "color": "red", "reset_in": 60, "camera": "Front Door", "quiet": false }
```

---

### `POST /reset`
Manually clears the alert — sets state to **green** immediately, cancels the timer.

```bash
curl -X POST \
  -H "Authorization: Bearer secret" \
  http://127.0.0.1:3000/reset

# Shortcut
trigctl reset
```

**Response:**
```json
{ "status": "ok", "color": "green" }
```

---

### `GET /events`
Server-Sent Events stream. Sends current state immediately on connect, then pushes updates on every change. Used by both the alert page and the dashboard.

```bash
curl -N http://127.0.0.1:3000/events
```

**Event format:**
```
data: {"color":"red","reset_in":42,"camera":"Front Door","quiet":false}
```

`color` is `"green"`, `"red"`, or `"amber"` (red during quiet hours). A 30-second heartbeat comment (`: ping`) keeps proxy connections alive.

---

### `POST /snapshot`
Stores a camera snapshot image in memory (max `SNAPSHOT_MAX_BYTES`, up to 20 cameras). Requires auth.

```bash
curl -X POST \
  -H "Authorization: Bearer secret" \
  -H "Content-Type: image/jpeg" \
  --data-binary @frame.jpg \
  "http://127.0.0.1:3000/snapshot?camera=Front+Door"
```

**Response:**
```json
{ "status": "ok", "camera": "Front Door", "bytes": 48210 }
```

---

### `GET /snapshot/:camera`
Serves the most recent stored snapshot for a camera. Returns `404` if no snapshot exists or if it has expired (`SNAPSHOT_TTL`).

```bash
curl http://127.0.0.1:3000/snapshot/Front%20Door > frame.jpg
```

---

### `GET /api/snapshots`
Lists cameras that currently have a live (non-expired) snapshot. The active alert camera is sorted first.

```bash
curl http://127.0.0.1:3000/api/snapshots
```

**Response:**
```json
{ "cameras": ["Front Door", "Garage", "Backyard"] }
```

---

### `GET /api/history`
Returns the last 100 alert records, newest first.

```bash
curl http://127.0.0.1:3000/api/history
```

**Response:**
```json
[
  { "camera": "Front Door", "ts": 1712700000, "cleared_at": 1712700060,
    "cleared_by": "auto", "duration": 60 },
  ...
]
```

`cleared_by` is `"auto"` (countdown), `"manual"` (reset API), `"replaced"` (new alert before reset), or `null` (still active).

---

### `GET /` *(triggered.pl)*
The alert page — a full-screen colour display that reacts to the SSE stream.
Green = **OK**, Red = **ALERT** with a live countdown, Amber = **QUIET** (alert during quiet hours).

---

### `GET /api/log-stream` *(dashboard.pl)*
SSE stream that sends the last 100 lines of the log file on connect, then tails new entries in real time. Each event is a JSON object:

```
data: {"type":"line","text":"[2026-04-10 10:00:00] [info] Alert triggered","historic":false}
```

```bash
curl -N http://127.0.0.1:3001/api/log-stream
```

---

### `GET /api/ping` *(dashboard.pl)*
Health check.

```bash
curl http://127.0.0.1:3001/api/ping
# {"status":"ok","ts":1234567890}
```

---

## Debug Logging

Both scripts support a `DEBUG=1` mode that emits verbose diagnostic output using Mojolicious's native `debug` log level, writing to the same log file as normal output.

```bash
# Enable via CLI
DEBUG=1 trigctl start

# Enable permanently in .trigctl.env
echo 'DEBUG=1' >> .trigctl.env
```

When `DEBUG=1`:

**triggered.pl** logs:
- Full config/env dump at startup (token value redacted)
- Raw webhook body and extracted camera name
- Camera filtering decisions (allowed / suppressed + reason)
- State transitions (previous → new color)
- `arm_timer` arm/replace/fire events with timer IDs
- `notify_clients` call with client count and broadcast payload
- SSE client connect and disconnect with counts
- Push notification URL, outcome, and HTTP status
- Quiet hours check result on every 60-second tick
- Snapshot store, eviction, and total count

**dashboard.pl** logs:
- Full config/env dump at startup
- Log tail operations — file open, total lines, seek position
- New lines found on each 0.5-second poll tick
- Log file not-found polling and file-appearance events
- Snapshot proxy requests — upstream URL, HTTP status, bytes, content-type
- SSE log-stream client connect and disconnect

Debug lines appear in **cyan** in the dashboard's log viewer.

---

## Usage Examples

### Blue Iris — Silent Tripwire Motion Alert

[Blue Iris](https://blueirissoftware.com) is a Windows-based video surveillance platform that supports webhook **Alert Actions** on any camera trigger. Pairing it with `triggered.pl` turns any motion event into a silent, instantaneous full-screen visual alert on any connected browser — no sound, no popup, no notification fatigue.

**Setup:**

1. Configure `.trigctl.env` for LAN access and start:
   ```
   LISTEN_HOST=0.0.0.0
   WEBHOOK_TOKEN=webhook_token
   ```
   ```bash
   trigctl start
   ```

2. In Blue Iris, open **Camera Properties → Alerts → On alert…** and add a **Web request** action:

   | Field | Value |
   |---|---|
   | **URL** | `http://<alert-server-ip>:3000/webhook` |
   | **Post/Payload** | `camera:&CAM` |
   | **Add HTTP Headers** | `Authorization: Bearer webhook_token` |

4. Open `http://<alert-server-ip>:3000` (or the dashboard at `:3001`) on any browser, TV, or secondary monitor you want to act as a silent sentry display.

**How it works:**

- Blue Iris detects motion → fires the webhook → all open browser windows flip to **red** instantly
- The triggering camera's name (via `&CAM` substitution in the request body) is displayed prominently on the alert screen and in the dashboard status panel
- Set `ALERT_SOUND=/path/to/alert.mp3` in `.trigctl.env` to enable an in-browser audio alert — a 🔊/🔇 toggle button appears on both the alert page and dashboard
- No desktop notifications — purely visual (and optionally audio), making it ideal as an unobtrusive background monitor or a dedicated wall-mounted display
- The screen auto-resets to **green** after `RESET_DELAY` seconds (default 60), or immediately when Blue Iris sends a reset via `POST /reset` on the **alert ends** action
- Multiple cameras can all point to the same webhook endpoint — any one of them triggers the alert, and the camera name identifies which one fired
- Use `CAMERA_IGNORE` to suppress noisy cameras, or `CAMERA_ALLOW` to restrict alerts to specific cameras only
- The dashboard at `:3001` logs each camera-triggered event with a timestamp in the live log viewer

**Optional — auto-reset when motion ends:**

Add a second Web request action under **On alert end…**:

| Field | Value |
|---|---|
| **URL** | `http://<alert-server-ip>:3000/reset` |
| **Post/Payload** | `camera:&CAM` |
| **Add HTTP Headers** | `Authorization: Bearer webhook_token` |

This clears the screen the moment Blue Iris considers the motion event over, rather than waiting for the countdown.

**Optional — push snapshots from Blue Iris:**

In Blue Iris's **On alert** action, add a second Web request to push the camera frame:

| Field | Value |
|---|---|
| **URL** | `http://<alert-server-ip>:3000/snapshot?camera=&CAM` |
| **Post/Payload** | *(image binary via Blue Iris HTTP post feature)* |
| **Add HTTP Headers** | `Authorization: Bearer webhook_token` |

Snapshots appear in the dashboard's camera viewer panel and are available for `SNAPSHOT_TTL` seconds.

---

### Trigger from a CI/CD pipeline

```bash
# GitHub Actions step
- name: Notify alert dashboard
  run: |
    curl -s -X POST \
      -H "Authorization: Bearer ${{ secrets.WEBHOOK_TOKEN }}" \
      https://alerts.example.com/webhook
```

### Trigger from a shell script or cron job

```bash
#!/bin/bash
# alert-on-failure.sh
if ! /usr/local/bin/check-service.sh; then
  curl -s -X POST \
    -H "Authorization: Bearer $WEBHOOK_TOKEN" \
    http://127.0.0.1:3000/webhook
fi
```

### Enable audio alert sound

Add to `.trigctl.env`:
```
ALERT_SOUND=/path/to/alert.mp3
```

The file is served by `triggered.pl` at `/alert-sound` and streamed to the browser.
A 🔊 toggle button appears on the alert page and dashboard — clicking it mutes/unmutes
without reloading. The sound only plays on the **green → red transition** (not on
repeated webhooks while already in alert state).

> **Browser autoplay note:** modern browsers require a user gesture before playing audio.
> The first click or tap on the alert page unlocks audio for that session.
> For unattended displays, open the page and tap once to prime it.

### Enable quiet hours

During quiet hours, incoming webhooks still record history but the alert state is set to **amber** rather than red, and the browser displays **QUIET** instead of **ALERT**. Add to `.trigctl.env`:

```
QUIET_START=22:00
QUIET_END=07:00
```

Time is in local 24h format. Midnight-wrapping ranges (e.g. `22:00`–`07:00`) are handled correctly.

### Enable push notifications

```
NOTIFY_URL=https://ntfy.sh/your-topic
NOTIFY_ON_RESET=1
```

Supported services: ntfy.sh, Slack incoming webhooks, Discord webhooks, or any generic HTTP endpoint that accepts a JSON POST. Notifications are sent asynchronously and never delay the webhook response.

---

### Production mode

```bash
trigctl start --prod    # starts both servers under hypnotoad
trigctl reload          # zero-downtime rolling restart (no dropped connections)
trigctl stop            # graceful shutdown
```

> **Important:** `triggered.pl` uses in-process shared state for SSE client tracking
> and alert colour, so it is pre-configured to run with `workers => 1`. Running
> multiple workers would cause each worker to maintain its own isolated state,
> breaking SSE fan-out. `dashboard.pl` is stateless and can use the default worker
> count without issue.

#### Manual hypnotoad commands (without trigctl)

```bash
WEBHOOK_TOKEN=secret LOG_FILE=./triggered.log \
  ALERT_SOUND=/path/to/alert.mp3 hypnotoad triggered.pl

WEBHOOK_TOKEN=secret TRIGGERED_LOG=./triggered.log \
  TRIGGERED_URL=http://<alert-server-ip>:3000 hypnotoad dashboard.pl

hypnotoad triggered.pl --stop
hypnotoad dashboard.pl --stop
```

---

## Dashboard

The React dashboard (served by `dashboard.pl`) gives you:

- **Status panel** — live colour indicator (green/red/amber), ALERT/OK/QUIET label, countdown timer, camera name, and sound toggle
- **Connection badges** — shows whether the alert server SSE stream and log stream are connected, connecting, or disconnected
- **Snapshot viewer** — tabbed live camera snapshots polled every 2 seconds; auto-switches to the triggering camera when an alert fires
- **Alert history** — last 20 alert records with camera name, timestamp, duration, and how the alert was cleared (auto / manual / replaced / active)
- **Log viewer** — last 500 lines of the triggered.pl log, colour-coded by level (info white, warn amber, error red, **debug cyan**), with auto-scroll and clear controls
- **Command reference** — copy-paste start/trigger/reset commands in the sidebar

The dashboard connects directly to `triggered.pl`'s `/events` endpoint for status updates (CORS is enabled on that route) and to its own `/api/log-stream` for the log tail. Snapshot images are proxied through `dashboard.pl` to avoid cross-origin image load issues.

---

## PWA — Install on Mobile / Tablet

The alert page (`triggered.pl /`) is a Progressive Web App. On any modern mobile browser:

- **iOS Safari** — tap the Share icon → **Add to Home Screen**
- **Android Chrome** — tap the menu → **Add to Home Screen** (or install prompt)

Once installed it launches fullscreen with no browser chrome, behaving like a native app.
The service worker caches the app shell so the last-known state is visible even offline.
SSE reconnects automatically when the network returns.

For the best wall-mount or bedside display experience, pair with your device's **Guided Access** (iOS) or **Screen Pinning** (Android) to lock the screen to the alert page.

---

## Security Notes

- `WEBHOOK_TOKEN` uses HTTP Bearer authentication. If unset, `/webhook`, `/reset`, and `/snapshot` are open to anyone who can reach the port — always set a token in any networked environment.
- Both scripts bind to `127.0.0.1` by default. Set `LISTEN_HOST=0.0.0.0` only if you need LAN/WAN access.
- For public-facing deployments, place both servers behind a TLS-terminating reverse proxy (nginx, Caddy) and set `LISTEN_HOST=127.0.0.1`.
- `.trigctl.env` contains your token — it is gitignored by default. Never commit it.
- For high-security environments, replace the `eq` bearer token comparison in `triggered.pl` with a constant-time comparison to prevent timing-based token enumeration.

---

## History

| File | Notes |
|---|---|
| `visual_alert_pre-timer-save` | First working version — no auto-reset timer |
| `visual_alert.pl` | Added 60-second auto-reset timer |
| `triggered.pl` | Full rewrite — auth, env config, JSON API, CORS, logging |
| `dashboard.pl` | React monitoring dashboard with live log tail |
| `trigctl` | Control script — unified start/stop/status/reload for both servers |
| *(current)* | Camera snapshots, alert history, quiet hours, push notifications, camera filtering, `DEBUG=1` logging |
