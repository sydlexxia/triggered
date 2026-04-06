#!/usr/bin/env perl
# dashboard.pl — monitoring dashboard for triggered.pl
# Requires: Mojolicious (cpanm --installdeps .)
# Perl >= 5.20 recommended
#
# Configuration (environment variables):
#   DASHBOARD_PORT  — listen port for this server   (default: 3001)
#   LISTEN_HOST     — bind address                  (default: 127.0.0.1)
#   TRIGGERED_URL   — base URL of triggered.pl      (default: http://127.0.0.1:3000)
#   TRIGGERED_LOG   — path to triggered.pl log file (default: ./triggered.log)
#   WEBHOOK_TOKEN   — bearer token (same as triggered.pl, optional)
#
# Endpoints:
#   GET /                — React dashboard page
#   GET /api/log-stream  — SSE stream of triggered.pl log file (tail)
#   GET /api/ping        — health check JSON
#
# The React frontend connects directly to triggered.pl's /events SSE endpoint
# for live alert status, and to /api/log-stream here for the log tail.
# Run triggered.pl first, then this script.

use 5.020;
use Mojolicious::Lite;
use Mojo::IOLoop;
use Mojo::JSON qw(encode_json);

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

my $port          = $ENV{DASHBOARD_PORT} // 3001;
my $host          = $ENV{LISTEN_HOST}    // '127.0.0.1';
my $triggered_url = $ENV{TRIGGERED_URL}  // 'http://127.0.0.1:3000';
my $log_file      = $ENV{TRIGGERED_LOG}  // './triggered.log';
my $token         = $ENV{WEBHOOK_TOKEN};

warn "[dashboard] WARNING: WEBHOOK_TOKEN is not set\n" unless $token;
warn "[dashboard] Tailing log: $log_file\n";
warn "[dashboard] Alert server: $triggered_url\n";

app->config(hypnotoad => {
    listen   => ["http://$host:$port"],
    pid_file => $ENV{HYPNOTOAD_PID} // '/tmp/dashboard-hypnotoad.pid',
});

app->hook(before_server_start => sub {
    my ($server, $app) = @_;
    $server->listen(["http://$host:$port"])
        if $server->isa('Mojo::Server::Daemon');
});

app->log->level('info');

# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

get '/api/ping' => sub {
    my $c = shift;
    $c->render(json => { status => 'ok', ts => time() });
};

# ---------------------------------------------------------------------------
# SSE log tail — sends last 100 lines on connect, then follows new writes
# ---------------------------------------------------------------------------

get '/api/log-stream' => sub {
    my $c = shift;

    $c->inactivity_timeout(0);
    $c->res->headers->content_type('text/event-stream');
    $c->res->headers->cache_control('no-cache');

    # If log file doesn't exist yet, poll until it appears
    unless (-e $log_file) {
        $c->write("data: " . encode_json({
            type => 'system',
            text => "Waiting for log file: $log_file",
        }) . "\n\n");

        my $watcher;
        $watcher = Mojo::IOLoop->recurring(2 => sub {
            return unless -e $log_file;
            Mojo::IOLoop->remove($watcher);
            $c->write("data: " . encode_json({
                type => 'system',
                text => 'Log file found — reconnect to load entries.',
            }) . "\n\n");
        });
        $c->on(finish => sub { Mojo::IOLoop->remove($watcher) });
        return;
    }

    open my $fh, '<', $log_file
        or do {
            $c->write("data: " . encode_json({
                type => 'error',
                text => "Cannot open log file: $!",
            }) . "\n\n");
            return;
        };

    # Send last 100 lines as history so the viewer isn't empty on connect
    my @all = <$fh>;
    my $start = @all > 100 ? @all - 100 : 0;
    for my $i ($start .. $#all) {
        chomp(my $line = $all[$i]);
        next unless length $line;
        $c->write("data: " . encode_json({
            type     => 'line',
            text     => $line,
            historic => \1,
        }) . "\n\n");
    }

    # Seek to end and tail new lines every 500 ms
    seek $fh, 0, 2;

    my $tail_timer = Mojo::IOLoop->recurring(0.5 => sub {
        while (defined(my $line = <$fh>)) {
            chomp $line;
            next unless length $line;
            $c->write("data: " . encode_json({
                type     => 'line',
                text     => $line,
                historic => \0,
            }) . "\n\n");
        }
    });

    my $hb_timer = Mojo::IOLoop->recurring(30 => sub {
        $c->write(": ping\n\n");
    });

    $c->on(finish => sub {
        Mojo::IOLoop->remove($tail_timer);
        Mojo::IOLoop->remove($hb_timer);
        close $fh;
    });
};

# ---------------------------------------------------------------------------
# Dashboard page — injects server config as JS globals for the React app
# ---------------------------------------------------------------------------

get '/' => sub {
    my $c = shift;
    $c->stash(
        triggered_url => $triggered_url,
        reset_delay   => $ENV{RESET_DELAY} // 60,
    );
    $c->render('dashboard');
};

app->start;

# ---------------------------------------------------------------------------
# Embedded templates
# ---------------------------------------------------------------------------

__DATA__

@@ dashboard.html.ep
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Visual Alert — Dashboard</title>

  <!-- React 18 + Babel standalone (no build step) -->
  <script crossorigin src="https://unpkg.com/react@18/umd/react.development.js"></script>
  <script crossorigin src="https://unpkg.com/react-dom@18/umd/react-dom.development.js"></script>
  <script src="https://unpkg.com/@babel/standalone/babel.min.js"></script>

  <!-- Server-injected config -->
  <script>
    window.__CFG__ = {
      triggeredUrl: '<%== $triggered_url %>',
      resetDelay:   <%= $reset_delay %>,
    };
  </script>

  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    :root {
      --bg:        #0f172a;
      --surface:   #1e293b;
      --border:    #334155;
      --text:      #f1f5f9;
      --muted:     #94a3b8;
      --green:     #22c55e;
      --green-dim: #166534;
      --red:       #ef4444;
      --red-dim:   #7f1d1d;
      --amber:     #f59e0b;
      --blue:      #3b82f6;
      --cyan:      #06b6d4;
      --radius:    8px;
    }

    html, body, #root { height: 100%; }

    body {
      background: var(--bg);
      color: var(--text);
      font-family: system-ui, -apple-system, sans-serif;
      font-size: 14px;
      line-height: 1.5;
    }

    /* ── Layout ─────────────────────────────────────────── */
    .layout {
      display: grid;
      grid-template-rows: auto 1fr auto;
      grid-template-columns: 1fr 260px;
      grid-template-areas:
        "header  header"
        "main    sidebar"
        "log     log";
      gap: 12px;
      padding: 12px;
      height: 100%;
      min-height: 100vh;
    }

    @media (max-width: 700px) {
      .layout {
        grid-template-columns: 1fr;
        grid-template-areas:
          "header"
          "main"
          "sidebar"
          "log";
      }
    }

    /* ── Card ────────────────────────────────────────────── */
    .card {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 16px;
    }

    .card-title {
      font-size: 11px;
      font-weight: 600;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      color: var(--muted);
      margin-bottom: 12px;
    }

    /* ── Header ──────────────────────────────────────────── */
    .header {
      grid-area: header;
      display: flex;
      align-items: center;
      justify-content: space-between;
    }

    .header-title {
      font-size: 16px;
      font-weight: 700;
      letter-spacing: 0.03em;
    }

    .header-title span { color: var(--muted); font-weight: 400; margin-left: 6px; font-size: 13px; }

    .clock { color: var(--muted); font-variant-numeric: tabular-nums; font-size: 13px; }

    /* ── Status panel ────────────────────────────────────── */
    .status-card {
      grid-area: main;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 18px;
      min-height: 220px;
    }

    .status-orb {
      width: 100px;
      height: 100px;
      border-radius: 50%;
      transition: background 0.4s ease, box-shadow 0.4s ease;
    }

    .orb-green {
      background: var(--green);
      box-shadow: 0 0 30px rgba(34,197,94,0.4);
    }

    .orb-red {
      background: var(--red);
      animation: pulse-red 1.4s ease-in-out infinite;
    }

    .orb-unknown {
      background: var(--border);
    }

    @keyframes pulse-red {
      0%, 100% { box-shadow: 0 0 0 0 rgba(239,68,68,0.5); }
      50%       { box-shadow: 0 0 0 24px rgba(239,68,68,0); }
    }

    .status-label {
      font-size: 3rem;
      font-weight: 800;
      letter-spacing: 0.06em;
      transition: color 0.4s ease;
    }

    .label-green   { color: var(--green); }
    .label-red     { color: var(--red); }
    .label-unknown { color: var(--muted); }

    .status-camera {
      font-size: 1rem;
      font-weight: 600;
      letter-spacing: 0.04em;
      min-height: 1.4em;
      transition: color 0.4s ease;
    }
    .status-camera.cam-red   { color: #fca5a5; }
    .status-camera.cam-green { color: var(--muted); }

    .status-countdown {
      font-size: 1rem;
      color: var(--muted);
      min-height: 1.4em;
      font-variant-numeric: tabular-nums;
    }

    .sound-btn {
      background: none;
      border: 1px solid var(--border);
      border-radius: 6px;
      color: var(--muted);
      font-size: 1rem;
      padding: 4px 10px;
      cursor: pointer;
      line-height: 1;
    }
    .sound-btn:hover { border-color: var(--text); color: var(--text); }

    /* ── Sidebar ─────────────────────────────────────────── */
    .sidebar { grid-area: sidebar; display: flex; flex-direction: column; gap: 12px; }

    .conn-row {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 4px 0;
      font-size: 13px;
    }

    .conn-label { color: var(--muted); }

    .badge {
      display: inline-flex;
      align-items: center;
      gap: 5px;
      font-size: 11px;
      font-weight: 600;
      padding: 2px 8px;
      border-radius: 99px;
    }

    .badge::before {
      content: '';
      display: block;
      width: 6px;
      height: 6px;
      border-radius: 50%;
    }

    .badge-connected    { background: rgba(34,197,94,0.15);  color: var(--green); }
    .badge-connected::before { background: var(--green); }
    .badge-connecting   { background: rgba(245,158,11,0.15); color: var(--amber); }
    .badge-connecting::before { background: var(--amber); animation: blink 1s step-end infinite; }
    .badge-disconnected { background: rgba(239,68,68,0.15);  color: var(--red); }
    .badge-disconnected::before { background: var(--red); }

    @keyframes blink { 50% { opacity: 0; } }

    .cmd-block {
      background: var(--bg);
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 10px 12px;
      font-family: ui-monospace, 'Cascadia Code', monospace;
      font-size: 12px;
      color: var(--cyan);
      line-height: 1.8;
    }

    .cmd-comment { color: var(--muted); }

    /* ── Log viewer ──────────────────────────────────────── */
    .log-card { grid-area: log; display: flex; flex-direction: column; max-height: 320px; }

    .log-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 10px;
      flex-shrink: 0;
    }

    .log-controls { display: flex; gap: 8px; align-items: center; }

    .toggle-btn {
      display: inline-flex;
      align-items: center;
      gap: 5px;
      background: none;
      border: 1px solid var(--border);
      border-radius: 6px;
      color: var(--muted);
      font-size: 12px;
      padding: 3px 10px;
      cursor: pointer;
      transition: border-color 0.15s, color 0.15s;
    }

    .toggle-btn.active { border-color: var(--blue); color: var(--blue); }
    .toggle-btn:hover  { border-color: var(--text); color: var(--text); }

    .clear-btn {
      background: none;
      border: 1px solid var(--border);
      border-radius: 6px;
      color: var(--muted);
      font-size: 12px;
      padding: 3px 10px;
      cursor: pointer;
    }
    .clear-btn:hover { border-color: var(--red); color: var(--red); }

    .log-body {
      flex: 1;
      overflow-y: auto;
      font-family: ui-monospace, 'Cascadia Code', 'Fira Code', monospace;
      font-size: 12px;
      line-height: 1.6;
      background: var(--bg);
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 8px 12px;
    }

    .log-body::-webkit-scrollbar { width: 6px; }
    .log-body::-webkit-scrollbar-track { background: transparent; }
    .log-body::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }

    .log-line { white-space: pre-wrap; word-break: break-all; padding: 1px 0; }
    .log-line.historic { opacity: 0.55; }
    .log-line.lvl-error { color: #fca5a5; }
    .log-line.lvl-warn  { color: #fcd34d; }
    .log-line.lvl-debug { color: #67e8f9; }
    .log-line.lvl-info  { color: var(--text); }
    .log-line.lvl-system { color: var(--amber); font-style: italic; }

    .log-empty { color: var(--muted); font-style: italic; padding: 8px 0; }
  </style>
</head>
<body>
<div id="root"></div>

<script type="text/babel">
const { useState, useEffect, useRef, useCallback } = React;
const CFG = window.__CFG__;

// ── Helpers ────────────────────────────────────────────────────────────────

function lineLevel(text) {
  if (/\[(error|fatal)\]/i.test(text)) return 'lvl-error';
  if (/\[warn\]/i.test(text))          return 'lvl-warn';
  if (/\[debug\]/i.test(text))         return 'lvl-debug';
  return 'lvl-info';
}

function ConnectionBadge({ state }) {
  return <span className={`badge badge-${state}`}>{state}</span>;
}

function Clock() {
  const [t, setT] = useState(new Date());
  useEffect(() => {
    const id = setInterval(() => setT(new Date()), 1000);
    return () => clearInterval(id);
  }, []);
  return (
    <span className="clock">
      {t.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })}
    </span>
  );
}

// ── Status Panel ───────────────────────────────────────────────────────────

function StatusPanel({ color, camera, countdown, connState, soundAvailable, soundMuted, onSoundToggle }) {
  const orbClass   = color === 'red' ? 'orb-red'   : color === 'green' ? 'orb-green'   : 'orb-unknown';
  const labelClass = color === 'red' ? 'label-red'  : color === 'green' ? 'label-green' : 'label-unknown';
  const labelText  = color === 'red' ? 'ALERT'      : color === 'green' ? 'OK'          : '—';

  return (
    <div className="card status-card">
      <div className={`status-orb ${orbClass}`} />
      <div className={`status-label ${labelClass}`}>{labelText}</div>
      <div className={`status-camera ${color === 'red' ? 'cam-red' : 'cam-green'}`}>
        {color === 'red' && camera ? camera : ''}
      </div>
      <div className="status-countdown">
        {color === 'red' && countdown > 0
          ? `Auto-reset in ${countdown}s`
          : color === 'green'
          ? 'All clear'
          : 'Connecting to alert server…'}
      </div>
      <div style={{display:'flex', gap:'8px', alignItems:'center'}}>
        <ConnectionBadge state={connState} />
        {soundAvailable && (
          <button className="sound-btn" onClick={onSoundToggle} title="Toggle alert sound">
            {soundMuted ? '🔇' : '🔊'}
          </button>
        )}
      </div>
    </div>
  );
}

// ── Log Viewer ─────────────────────────────────────────────────────────────

function LogViewer({ lines, connState, autoScroll, setAutoScroll, onClear }) {
  const bodyRef = useRef(null);

  useEffect(() => {
    if (autoScroll && bodyRef.current) {
      bodyRef.current.scrollTop = bodyRef.current.scrollHeight;
    }
  }, [lines, autoScroll]);

  const handleScroll = useCallback(() => {
    const el = bodyRef.current;
    if (!el) return;
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 32;
    setAutoScroll(atBottom);
  }, [setAutoScroll]);

  return (
    <div className="card log-card">
      <div className="log-header">
        <span className="card-title" style={{marginBottom: 0}}>Log Output</span>
        <div className="log-controls">
          <ConnectionBadge state={connState} />
          <button
            className={`toggle-btn ${autoScroll ? 'active' : ''}`}
            onClick={() => setAutoScroll(v => !v)}
            title="Toggle auto-scroll"
          >
            ↓ auto-scroll
          </button>
          <button className="clear-btn" onClick={onClear} title="Clear display">
            clear
          </button>
        </div>
      </div>
      <div className="log-body" ref={bodyRef} onScroll={handleScroll}>
        {lines.length === 0
          ? <div className="log-empty">No log entries yet.</div>
          : lines.map(l => (
              <div
                key={l.id}
                className={`log-line ${l.historic ? 'historic' : ''} ${l.level}`}
              >{l.text}</div>
            ))
        }
      </div>
    </div>
  );
}

// ── Sidebar ────────────────────────────────────────────────────────────────

function Sidebar({ statusConn, logConn }) {
  return (
    <div className="sidebar">
      <div className="card">
        <div className="card-title">Connections</div>
        <div className="conn-row">
          <span className="conn-label">alert server</span>
          <ConnectionBadge state={statusConn} />
        </div>
        <div className="conn-row">
          <span className="conn-label">log stream</span>
          <ConnectionBadge state={logConn} />
        </div>
      </div>

      <div className="card">
        <div className="card-title">Start Commands</div>
        <div className="cmd-block">
          <div className="cmd-comment"># development (default)</div>
          <div>trigctl start</div>
          <br/>
          <div className="cmd-comment"># production (hypnotoad)</div>
          <div>trigctl start --prod</div>
          <br/>
          <div className="cmd-comment"># status &amp; client count</div>
          <div>trigctl status</div>
          <br/>
          <div className="cmd-comment"># trigger / reset</div>
          <div>trigctl trigger "Camera"</div>
          <div>trigctl reset</div>
          <br/>
          <div className="cmd-comment"># stop</div>
          <div>trigctl stop</div>
        </div>
      </div>
    </div>
  );
}

// ── App ────────────────────────────────────────────────────────────────────

function App() {
  const [alertColor,     setAlertColor]     = useState('unknown');
  const [cameraName,     setCameraName]     = useState('');
  const [countdown,      setCountdown]      = useState(0);
  const [statusConn,     setStatusConn]     = useState('connecting');
  const [logLines,       setLogLines]       = useState([]);
  const [logConn,        setLogConn]        = useState('connecting');
  const [autoScroll,     setAutoScroll]     = useState(true);
  const [soundAvailable, setSoundAvailable] = useState(false);
  const [soundMuted,     setSoundMuted]     = useState(false);
  const countdownRef = useRef(null);
  const lineIdRef    = useRef(0);
  const audioRef     = useRef(null);
  const prevColorRef = useRef('unknown');

  // ── Check if alert sound is available on triggered.pl ────────────────────
  useEffect(() => {
    fetch(`${CFG.triggeredUrl}/alert-sound`, { method: 'HEAD' })
      .then(r => {
        if (r.ok) {
          audioRef.current = new Audio(`${CFG.triggeredUrl}/alert-sound`);
          setSoundAvailable(true);
        }
      })
      .catch(() => {});
  }, []);

  // ── Status SSE (direct to triggered.pl) ──────────────────────────────────
  useEffect(() => {
    const es = new EventSource(`${CFG.triggeredUrl}/events`);

    es.onopen = () => setStatusConn('connected');

    es.onmessage = (e) => {
      const data = JSON.parse(e.data);
      setCameraName(data.camera || '');
      setAlertColor(data.color);

      // Play sound on green → red transition
      if (data.color === 'red' && prevColorRef.current !== 'red') {
        if (audioRef.current && !soundMuted) {
          audioRef.current.currentTime = 0;
          audioRef.current.play().catch(() => {});
        }
      }
      prevColorRef.current = data.color;

      if (countdownRef.current) {
        clearInterval(countdownRef.current);
        countdownRef.current = null;
      }

      if (data.color === 'red' && data.reset_in > 0) {
        let rem = data.reset_in;
        setCountdown(rem);
        countdownRef.current = setInterval(() => {
          rem--;
          if (rem <= 0) {
            clearInterval(countdownRef.current);
            countdownRef.current = null;
            setCountdown(0);
          } else {
            setCountdown(rem);
          }
        }, 1000);
      } else {
        setCountdown(0);
      }
    };

    es.onerror = () => setStatusConn('disconnected');

    return () => {
      es.close();
      if (countdownRef.current) clearInterval(countdownRef.current);
    };
  }, [soundMuted]);

  // ── Log SSE (via dashboard.pl) ────────────────────────────────────────────
  useEffect(() => {
    const es = new EventSource('/api/log-stream');

    es.onopen = () => setLogConn('connected');

    es.onmessage = (e) => {
      const data = JSON.parse(e.data);
      if (data.type === 'line') {
        const entry = {
          id:       lineIdRef.current++,
          text:     data.text,
          historic: data.historic,
          level:    lineLevel(data.text),
        };
        setLogLines(prev => {
          const next = [...prev, entry];
          return next.length > 500 ? next.slice(-500) : next;
        });
      } else if (data.type === 'system' || data.type === 'error') {
        setLogLines(prev => {
          const entry = { id: lineIdRef.current++, text: `[dashboard] ${data.text}`, historic: false, level: 'lvl-system' };
          return [...prev, entry].slice(-500);
        });
      }
    };

    es.onerror = () => setLogConn('disconnected');
    return () => es.close();
  }, []);

  const clearLog = useCallback(() => setLogLines([]), []);

  return (
    <div className="layout">
      <header className="card header">
        <div className="header-title">
          Visual Alert
          <span>Dashboard</span>
        </div>
        <Clock />
      </header>

      <StatusPanel
        color={alertColor}
        camera={cameraName}
        countdown={countdown}
        connState={statusConn}
        soundAvailable={soundAvailable}
        soundMuted={soundMuted}
        onSoundToggle={() => setSoundMuted(m => !m)}
      />

      <Sidebar statusConn={statusConn} logConn={logConn} />

      <LogViewer
        lines={logLines}
        connState={logConn}
        autoScroll={autoScroll}
        setAutoScroll={setAutoScroll}
        onClear={clearLog}
      />
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
</script>
</body>
</html>
