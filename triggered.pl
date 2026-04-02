#!/usr/bin/env perl
# triggered.pl — visual alert server (improved)
# Requires: Mojolicious (cpanm --installdeps .)
# Perl >= 5.20 recommended
#
# Configuration (environment variables):
#   PORT           — listen port            (default: 3000)
#   LISTEN_HOST    — bind address           (default: 127.0.0.1)
#   RESET_DELAY    — auto-reset seconds     (default: 60)
#   WEBHOOK_TOKEN  — bearer token for auth  (default: unset = unauthenticated)
#   LOG_FILE       — path to log file       (default: ./triggered.log)
#   ALERT_SOUND    — path to audio file to play on alert (default: unset = silent)
#                    supports .mp3 .wav .ogg .m4a — served to browser at /alert-sound
#
# Endpoints:
#   GET  /             — alert page (SSE-driven, PWA-installable)
#   GET  /events       — Server-Sent Events stream
#   POST /webhook      — trigger alert; optional JSON body: {"camera":"name"}
#   POST /reset        — manually clear alert (set green)
#   GET  /alert-sound  — serves the ALERT_SOUND file (only if env var is set)
#   GET  /manifest.json, /icon.svg, /sw.js — PWA assets
#
# Deploy behind a TLS-terminating reverse proxy (nginx, caddy) for HTTPS.

use 5.020;
use Mojolicious::Lite;
use Mojo::IOLoop;
use Mojo::JSON qw(encode_json);
use Mojo::Asset::File;

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

my $port        = $ENV{PORT}         // 3000;
my $host        = $ENV{LISTEN_HOST}  // '127.0.0.1';
my $reset_delay = $ENV{RESET_DELAY}  // 60;
my $token       = $ENV{WEBHOOK_TOKEN};
my $log_file    = $ENV{LOG_FILE}     // './triggered.log';
my $alert_sound = $ENV{ALERT_SOUND};  # e.g. /path/to/alert.mp3

if ($alert_sound && !-e $alert_sound) {
    warn "[triggered] WARNING: ALERT_SOUND file not found: $alert_sound\n";
    $alert_sound = undef;
}

unless ($token) {
    warn "[triggered] WARNING: WEBHOOK_TOKEN is not set — "
       . "/webhook and /reset are unauthenticated\n";
}

# hypnotoad listen (production mode)
# workers => 1 is required: triggered.pl uses in-process shared state
# ($color, $clients, $timer_id) which is not shared across forked workers.
# A multi-worker deployment would need an external broker (e.g. Redis pub/sub).
app->config(hypnotoad => { listen => ["http://$host:$port"], workers => 1 });

# daemon listen (development mode) — app->config(hypnotoad) is ignored by
# the daemon server, so we hook before_server_start to apply the same
# LISTEN_HOST / PORT env vars regardless of which server mode is used.
app->hook(before_server_start => sub {
    my ($server, $app) = @_;
    $server->listen(["http://$host:$port"])
        if $server->isa('Mojo::Server::Daemon');
});

app->log->path($log_file);
app->log->level('info');

# ---------------------------------------------------------------------------
# Shared state
# ---------------------------------------------------------------------------

my $color       = 'green';
my $clients     = {};
my $timer_id;
my $alert_time;    # epoch when alert was last triggered
my $camera_name = '';  # camera that triggered the current alert

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Check bearer token.  Uses string comparison — for a public-facing service,
# replace with a constant-time comparison (e.g. Crypt::ScryptKDF or
# String::Compare::ConstantTime) to prevent timing-based token enumeration.
sub authorized {
    my $c = shift;
    return 1 unless $token;
    my $auth = $c->req->headers->authorization // '';
    return $auth eq "Bearer $token";
}

sub reset_remaining {
    return 0 unless defined $alert_time;
    my $rem = $reset_delay - (time() - $alert_time);
    return $rem > 0 ? int($rem) : 0;
}

sub notify_clients {
    my $payload = encode_json({
        color    => $color,
        reset_in => reset_remaining(),
        camera   => $camera_name,
    });
    for my $id (keys %$clients) {
        $clients->{$id}->write("data: $payload\n\n");
    }
}

sub arm_timer {
    Mojo::IOLoop->remove($timer_id) if $timer_id;
    $timer_id = Mojo::IOLoop->timer($reset_delay => sub {
        $color       = 'green';
        $alert_time  = undef;
        $timer_id    = undef;
        $camera_name = '';
        notify_clients();
    });
}

# ---------------------------------------------------------------------------
# SSE heartbeat — keeps connections alive through proxies and load balancers
# ---------------------------------------------------------------------------

Mojo::IOLoop->recurring(30 => sub {
    for my $id (keys %$clients) {
        $clients->{$id}->write(": ping\n\n");
    }
});

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

# Trigger alert
post '/webhook' => sub {
    my $c = shift;
    return $c->render(json => { error => 'Unauthorized' }, status => 401)
        unless authorized($c);

    my $body    = eval { $c->req->json } // {};
    $camera_name = $body->{camera} // $c->req->param('camera') // '';
    $color       = 'red';
    $alert_time  = time();
    arm_timer();
    notify_clients();
    my $cam_info = $camera_name ? " (camera: $camera_name)" : '';
    app->log->info("Alert triggered via webhook$cam_info");
    $c->render(json => { status => 'ok', color => $color, reset_in => $reset_delay, camera => $camera_name });
};

# Manual reset
post '/reset' => sub {
    my $c = shift;
    return $c->render(json => { error => 'Unauthorized' }, status => 401)
        unless authorized($c);

    Mojo::IOLoop->remove($timer_id) if $timer_id;
    $timer_id    = undef;
    $color       = 'green';
    $alert_time  = undef;
    $camera_name = '';
    notify_clients();
    app->log->info("Alert manually reset");
    $c->render(json => { status => 'ok', color => $color });
};

# SSE stream — sends current state immediately, then pushes updates
get '/events' => sub {
    my $c = shift;
    $c->inactivity_timeout(300);

    my $stream = Mojo::IOLoop->stream($c->tx->connection);
    my $id     = $c->tx->connection;
    $clients->{$id} = $stream;
    $stream->on(close => sub { delete $clients->{$id} });

    $c->res->headers->content_type('text/event-stream');
    $c->res->headers->cache_control('no-cache');
    $c->res->headers->header('Access-Control-Allow-Origin' => '*');

    my $payload = encode_json({ color => $color, reset_in => reset_remaining(), camera => $camera_name });
    $c->write("data: $payload\n\n");
};

# Status page — passes sound_url into the template
get '/' => sub {
    my $c = shift;
    $c->stash(sound_url => $alert_sound ? '/alert-sound' : '');
    $c->render('index');
};

# Serve audio file for in-browser alert sound
get '/alert-sound' => sub {
    my $c = shift;
    return $c->reply->not_found unless $alert_sound && -e $alert_sound;
    my $mime = 'audio/mpeg';
    $mime = 'audio/wav'  if $alert_sound =~ /\.wav$/i;
    $mime = 'audio/ogg'  if $alert_sound =~ /\.ogg$/i;
    $mime = 'audio/mp4'  if $alert_sound =~ /\.m4a$/i;
    $c->res->headers->content_type($mime);
    $c->reply->asset(Mojo::Asset::File->new(path => $alert_sound));
};

# PWA — web app manifest
get '/manifest.json' => sub {
    my $c = shift;
    $c->res->headers->content_type('application/manifest+json');
    $c->render(json => {
        name             => 'Visual Alert',
        short_name       => 'Alert',
        start_url        => '/',
        display          => 'fullscreen',
        orientation      => 'any',
        background_color => '#15803d',
        theme_color      => '#15803d',
        icons            => [{
            src     => '/icon.svg',
            sizes   => 'any',
            type    => 'image/svg+xml',
            purpose => 'any maskable',
        }],
    });
};

# PWA — app icon (green/red circle, colour matches OK state)
get '/icon.svg' => sub {
    my $c = shift;
    $c->res->headers->content_type('image/svg+xml');
    $c->render(text =>
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">'
      . '<circle cx="50" cy="50" r="46" fill="#15803d"/>'
      . '<circle cx="50" cy="50" r="30" fill="#22c55e"/>'
      . '</svg>'
    );
};

# PWA — service worker (network-first, bypasses cache for SSE/API routes)
get '/sw.js' => sub {
    my $c = shift;
    $c->res->headers->content_type('application/javascript');
    $c->render(text => <<'END_SW');
const CACHE = 'visual-alert-v1';
const BYPASS = ['/events', '/webhook', '/reset', '/alert-sound'];

self.addEventListener('install',  () => self.skipWaiting());
self.addEventListener('activate', () => clients.claim());

self.addEventListener('fetch', e => {
  if (BYPASS.some(p => e.request.url.includes(p))) return;
  e.respondWith(
    caches.open(CACHE).then(cache =>
      fetch(e.request)
        .then(res => { cache.put(e.request, res.clone()); return res; })
        .catch(() => cache.match(e.request))
    )
  );
});
END_SW
};

app->start;

# ---------------------------------------------------------------------------
# Embedded templates
# ---------------------------------------------------------------------------

__DATA__

@@ index.html.ep
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="theme-color" content="#15803d" id="theme-meta">
  <meta name="mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
  <meta name="apple-mobile-web-app-title" content="Alert">
  <link rel="manifest" href="/manifest.json">
  <link rel="apple-touch-icon" href="/icon.svg">
  <title>Visual Alert</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      min-height: 100dvh;
      font-family: system-ui, sans-serif;
      background-color: #15803d;
      transition: background-color 0.4s ease;
      padding: env(safe-area-inset-top) env(safe-area-inset-right)
               env(safe-area-inset-bottom) env(safe-area-inset-left);
    }

    #panel {
      text-align: center;
      color: white;
      text-shadow: 0 2px 8px rgba(0,0,0,0.35);
      user-select: none;
    }

    #label {
      font-size: clamp(3rem, 18vw, 7rem);
      font-weight: 800;
      letter-spacing: 0.06em;
    }

    #camera {
      margin-top: 0.6rem;
      font-size: clamp(1rem, 4vw, 1.6rem);
      font-weight: 500;
      opacity: 0.9;
      min-height: 1.8em;
      letter-spacing: 0.04em;
    }

    #countdown {
      margin-top: 0.5rem;
      font-size: clamp(0.9rem, 3vw, 1.3rem);
      opacity: 0.75;
      min-height: 1.6em;
      font-variant-numeric: tabular-nums;
    }

    /* ── Corner controls ─────────────────────────────── */
    #controls {
      position: fixed;
      bottom: max(1rem, env(safe-area-inset-bottom));
      right: max(1rem, env(safe-area-inset-right));
      display: flex;
      gap: 10px;
      align-items: center;
    }

    .ctrl-btn {
      background: rgba(0,0,0,0.25);
      border: none;
      border-radius: 50%;
      width: 44px;
      height: 44px;
      font-size: 1.3rem;
      color: white;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
      -webkit-tap-highlight-color: transparent;
      touch-action: manipulation;
    }
    .ctrl-btn:active { transform: scale(0.92); }

    #conn-status {
      font-size: 0.75rem;
      opacity: 0.55;
      color: white;
    }
  </style>
</head>
<body>
  <div id="panel">
    <div id="label">OK</div>
    <div id="camera"></div>
    <div id="countdown"></div>
  </div>

  <div id="controls">
    <span id="conn-status">connecting…</span>
    % if ($sound_url) {
    <button class="ctrl-btn" id="sound-btn" title="Toggle sound">🔊</button>
    % }
  </div>

  <script>
    // ── Config injected by server ──────────────────────────
    var SOUND_URL = '<%== $sound_url %>';

    // ── Audio setup ────────────────────────────────────────
    var audio       = SOUND_URL ? new Audio(SOUND_URL) : null;
    var soundMuted  = false;
    var audioUnlocked = false;

    // Unlock audio context on first touch/click (browser autoplay policy)
    function unlockAudio() {
      if (!audio || audioUnlocked) return;
      audio.play().then(function () {
        audio.pause();
        audio.currentTime = 0;
        audioUnlocked = true;
      }).catch(function () {});
    }
    document.addEventListener('click',      unlockAudio, { once: false });
    document.addEventListener('touchstart', unlockAudio, { once: false });

    function playAlert() {
      if (!audio || soundMuted) return;
      audio.currentTime = 0;
      audio.play().catch(function () {});
    }

    var soundBtn = document.getElementById('sound-btn');
    if (soundBtn) {
      soundBtn.addEventListener('click', function () {
        soundMuted = !soundMuted;
        soundBtn.textContent = soundMuted ? '🔇' : '🔊';
      });
    }

    // ── SSE state ──────────────────────────────────────────
    var source           = new EventSource('/events');
    var countdownTimer   = null;
    var secondsRemaining = 0;
    var currentColor     = 'green';

    source.onopen = function () {
      document.getElementById('conn-status').textContent = 'connected';
    };

    source.onmessage = function (e) {
      var data = JSON.parse(e.data);
      applyState(data.color, data.reset_in || 0, data.camera || '');
    };

    source.onerror = function () {
      document.getElementById('conn-status').textContent = 'reconnecting…';
    };

    // ── State application ──────────────────────────────────
    function applyState(color, resetIn, camera) {
      var wasGreen = currentColor !== 'red';
      currentColor = color;

      document.body.style.backgroundColor =
        color === 'red' ? '#dc2626' : '#15803d';

      document.getElementById('theme-meta').setAttribute('content',
        color === 'red' ? '#dc2626' : '#15803d');

      document.getElementById('label').textContent =
        color === 'red' ? 'ALERT' : 'OK';

      document.getElementById('camera').textContent =
        (color === 'red' && camera) ? camera : '';

      clearInterval(countdownTimer);
      countdownTimer   = null;
      secondsRemaining = 0;
      document.getElementById('countdown').textContent = '';

      if (color === 'red') {
        if (wasGreen) playAlert();   // only play on transition green→red
        if (resetIn > 0) {
          secondsRemaining = resetIn;
          renderCountdown();
          countdownTimer = setInterval(function () {
            secondsRemaining--;
            if (secondsRemaining <= 0) {
              clearInterval(countdownTimer);
              countdownTimer = null;
              document.getElementById('countdown').textContent = '';
            } else {
              renderCountdown();
            }
          }, 1000);
        }
      }
    }

    function renderCountdown() {
      document.getElementById('countdown').textContent =
        'Auto-reset in ' + secondsRemaining + 's';
    }

    // ── PWA service worker ─────────────────────────────────
    if ('serviceWorker' in navigator) {
      navigator.serviceWorker.register('/sw.js').catch(function () {});
    }
  </script>
</body>
</html>
