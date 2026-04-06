# triggered

A lightweight, real-time visual alert system built with Perl + Mojolicious.
An external system (CI pipeline, monitoring tool, cron job, etc.) fires a webhook — every connected browser instantly flips to a red **ALERT** screen, then auto-resets to green after a configurable countdown.
A companion React dashboard provides a live status panel and real-time log viewer.

```
┌─────────────────────────────────────────────────────┐
│  triggered.pl          dashboard.pl                 │
│  :3000                 :3001                        │
│                                                     │
│  POST /webhook  ──►  SSE /events  ──►  browser      │
│  POST /reset          /api/log-stream               │
│  GET  /events         GET /                         │
└─────────────────────────────────────────────────────┘
```

---

## Files

| File | Description |
|---|---|
| `triggered.pl` | Alert server — webhook receiver, SSE broadcaster, auto-reset timer |
| `dashboard.pl` | Monitoring dashboard — React UI, live log tail over SSE |
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
| `WEBHOOK_TOKEN` | *(unset)* | Bearer token required on `/webhook` and `/reset`. If unset, endpoints are open — a warning is printed at startup |
| `LOG_FILE` | `./triggered.log` | Path to write log output |
| `ALERT_SOUND` | *(unset)* | Path to an audio file (`.mp3`, `.wav`, `.ogg`, `.m4a`) played in the browser when an alert fires. Served to the browser at `/alert-sound`. If unset, the alert is silent |

### dashboard.pl

| Variable | Default | Description |
|---|---|---|
| `DASHBOARD_PORT` | `3001` | Listen port |
| `LISTEN_HOST` | `127.0.0.1` | Bind address |
| `TRIGGERED_URL` | `http://127.0.0.1:3000` | Base URL of triggered.pl (used by the React frontend to connect to `/events`) |
| `TRIGGERED_LOG` | `./triggered.log` | Path to the triggered.pl log file to tail |
| `WEBHOOK_TOKEN` | *(unset)* | Same token as triggered.pl |

---

## API Reference

### `POST /webhook`
Triggers an alert — sets state to **red** and starts the auto-reset countdown.
Accepts an optional JSON body with a `camera` field; the camera name is broadcast
to all connected clients and displayed on the alert screen.

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

# Shortcut via trigctl (uses token from .trigctl.env)
trigctl trigger "Front Door"
```

**Response:**
```json
{ "status": "ok", "color": "red", "reset_in": 60, "camera": "Front Door" }
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
data: {"color":"red","reset_in":42,"camera":"Front Door"}
```

---

### `GET /`
The alert page — a full-screen colour display that reacts to the SSE stream.
Green = **OK**, Red = **ALERT** with a live countdown.

---

### `GET /api/log-stream` *(dashboard.pl)*
SSE stream that sends the last 100 lines of the log file on connect, then tails new entries in real time.

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

## Usage Examples

### Blue Iris — Silent Tripwire Motion Alert

[Blue Iris](https://blueirissoftware.com) is a Windows-based video surveillance platform that supports webhook **Alert Actions** on any camera trigger. Pairing it with `triggered.pl` turns any motion event into a silent, instantaneous full-screen visual alert on any connected browser — no sound, no popup, no notification fatigue.

**Setup:**

1. Configure `.trigctl.env` for LAN access and start:
   ```
   LISTEN_HOST=0.0.0.0
   WEBHOOK_TOKEN=secret
   ```
   ```bash
   trigctl start
   ```

2. In Blue Iris, open **Camera Properties → Alerts → On alert…** and add a **Web request** action:

   | Field | Value |
   |---|---|
   | **Method** | `POST` |
   | **URL** | `http://<alert-server-ip>:3000/webhook` |
   | **Header** | `Authorization: Bearer secret` |
   | **Body** | `{"camera":"&CAM"}` |

3. Open `http://<alert-server-ip>:3000` (or the dashboard at `:3001`) on any browser, TV, or secondary monitor you want to act as a silent sentry display.

**How it works:**

- Blue Iris detects motion → fires the webhook → all open browser windows flip to **red** instantly
- The triggering camera's name (via `&CAM` substitution in the request body) is displayed prominently on the alert screen and in the dashboard status panel
- Set `ALERT_SOUND=/path/to/alert.mp3` in `.trigctl.env` to enable an in-browser audio alert — a 🔊/🔇 toggle button appears on both the alert page and dashboard
- No desktop notifications — purely visual (and optionally audio), making it ideal as an unobtrusive background monitor or a dedicated wall-mounted display
- The screen auto-resets to **green** after `RESET_DELAY` seconds (default 60), or immediately when Blue Iris sends a reset via `POST /reset` on the **alert ends** action
- Multiple cameras can all point to the same webhook endpoint — any one of them triggers the alert, and the camera name identifies which one fired
- The dashboard at `:3001` logs each camera-triggered event with a timestamp in the live log viewer

**Optional — auto-reset when motion ends:**

Add a second Web request action under **On alert end…**:

| Field | Value |
|---|---|
| **Method** | `POST` |
| **URL** | `http://<alert-server-ip>:3000/reset` |
| **Header** | `Authorization: Bearer secret` |

This clears the screen the moment Blue Iris considers the motion event over, rather than waiting for the countdown.

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

- **Status panel** — live colour indicator, ALERT/OK label, countdown timer
- **Connection badges** — shows whether each SSE stream is connected, connecting, or disconnected
- **Log viewer** — last 500 lines of the triggered.pl log, colour-coded by level, with auto-scroll and clear controls
- **Command reference** — copy-paste start/trigger/reset commands in the sidebar

The dashboard connects directly to `triggered.pl`'s `/events` endpoint for status updates (CORS is enabled on that route) and to its own `/api/log-stream` for the log tail.

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

- `WEBHOOK_TOKEN` uses HTTP Bearer authentication. If unset, `/webhook` and `/reset` are open to anyone who can reach the port — always set a token in any networked environment.
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
