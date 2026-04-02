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
| `cpanfile` | Perl dependency declaration (`Mojolicious >= 9.0`) |
| `visual_alert.pl` | Original prototype (kept for reference) |

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

**Terminal 1 — start the alert server:**
```bash
WEBHOOK_TOKEN=secret LOG_FILE=./triggered.log perl triggered.pl daemon
```

**Terminal 2 — start the dashboard:**
```bash
WEBHOOK_TOKEN=secret TRIGGERED_LOG=./triggered.log perl dashboard.pl daemon
```

- Alert page: **http://127.0.0.1:3000**
- Dashboard: **http://127.0.0.1:3001**

---

## Configuration

All configuration is done via environment variables — no file editing required.

### triggered.pl

| Variable | Default | Description |
|---|---|---|
| `PORT` | `3000` | Listen port |
| `LISTEN_HOST` | `127.0.0.1` | Bind address |
| `RESET_DELAY` | `60` | Seconds before auto-reset to green |
| `WEBHOOK_TOKEN` | *(unset)* | Bearer token required on `/webhook` and `/reset`. If unset, endpoints are open — a warning is printed at startup |
| `LOG_FILE` | `./triggered.log` | Path to write log output |

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

```bash
curl -X POST \
  -H "Authorization: Bearer secret" \
  http://127.0.0.1:3000/webhook
```

**Response:**
```json
{ "status": "ok", "color": "red", "reset_in": 60 }
```

---

### `POST /reset`
Manually clears the alert — sets state to **green** immediately, cancels the timer.

```bash
curl -X POST \
  -H "Authorization: Bearer secret" \
  http://127.0.0.1:3000/reset
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
data: {"color":"red","reset_in":42}
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

1. Start `triggered.pl` on a LAN-accessible address so Blue Iris can reach it:
   ```bash
   LISTEN_HOST=0.0.0.0 PORT=3000 WEBHOOK_TOKEN=secret \
     LOG_FILE=./triggered.log perl triggered.pl daemon
   ```

2. In Blue Iris, open **Camera Properties → Alerts → On alert…** and add a **Web request** action:

   | Field | Value |
   |---|---|
   | **Method** | `POST` |
   | **URL** | `http://192.168.2.11:3000/webhook` |
   | **Header** | `Authorization: Bearer secret` |
   | **Body** | *(leave empty)* |

3. Open `http://192.168.2.11:3000` (or the dashboard at `:3001`) on any browser, TV, or secondary monitor you want to act as a silent sentry display.

**How it works:**

- Blue Iris detects motion → fires the webhook → all open browser windows flip to **red** instantly
- No audio, no desktop notifications — purely visual, making it ideal as an unobtrusive background monitor or a dedicated wall-mounted display
- The screen auto-resets to **green** after `RESET_DELAY` seconds (default 60), or immediately when Blue Iris sends a reset via `POST /reset` on the **alert ends** action
- Multiple cameras can all point to the same webhook endpoint — any one of them triggers the alert
- The dashboard at `:3001` logs each camera-triggered event with a timestamp in the live log viewer

**Optional — auto-reset when motion ends:**

Add a second Web request action under **On alert end…**:

| Field | Value |
|---|---|
| **Method** | `POST` |
| **URL** | `http://192.168.2.11:3000/reset` |
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

### Auto-reset after a custom delay

```bash
RESET_DELAY=300 WEBHOOK_TOKEN=secret LOG_FILE=./triggered.log \
  perl triggered.pl daemon
```

### Run on a LAN-accessible address

```bash
# Single instance reachable from all machines on the network
LISTEN_HOST=0.0.0.0 PORT=3000 WEBHOOK_TOKEN=secret \
  LOG_FILE=./triggered.log perl triggered.pl daemon

# Dashboard pointing to the network address
LISTEN_HOST=0.0.0.0 DASHBOARD_PORT=3001 \
  TRIGGERED_URL=http://192.168.2.11:3000 \
  TRIGGERED_LOG=./triggered.log \
  perl dashboard.pl daemon
```

### Production mode (hypnotoad)

```bash
# Start
WEBHOOK_TOKEN=secret LOG_FILE=./triggered.log hypnotoad triggered.pl

# Stop
hypnotoad triggered.pl --stop

# Hot-reload (zero downtime)
hypnotoad triggered.pl
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

## Security Notes

- `WEBHOOK_TOKEN` uses HTTP Bearer authentication. If unset, `/webhook` and `/reset` are open to anyone who can reach the port — always set a token in any networked environment.
- Both scripts bind to `127.0.0.1` by default. Set `LISTEN_HOST=0.0.0.0` only if you need LAN/WAN access.
- For public-facing deployments, place both servers behind a TLS-terminating reverse proxy (nginx, Caddy) and set `LISTEN_HOST=127.0.0.1`.
- For high-security environments, replace the `eq` bearer token comparison in `triggered.pl` with a constant-time comparison to prevent timing-based token enumeration.

---

## History

| File | Notes |
|---|---|
| `visual_alert_pre-timer-save` | First working version — no auto-reset timer |
| `visual_alert.pl` | Added 60-second auto-reset timer |
| `triggered.pl` | Full rewrite — auth, env config, JSON API, CORS, logging |
| `dashboard.pl` | React monitoring dashboard with live log tail |
