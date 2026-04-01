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
#
# Endpoints:
#   GET  /          — status page (SSE-driven background + label + countdown)
#   GET  /events    — Server-Sent Events stream
#   POST /webhook   — trigger alert (set red)
#   POST /reset     — manually clear alert (set green)
#
# Deploy behind a TLS-terminating reverse proxy (nginx, caddy) for HTTPS.

use 5.020;
use Mojolicious::Lite;
use Mojo::IOLoop;
use Mojo::JSON qw(encode_json);

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

my $port        = $ENV{PORT}         // 3000;
my $host        = $ENV{LISTEN_HOST}  // '127.0.0.1';
my $reset_delay = $ENV{RESET_DELAY}  // 60;
my $token       = $ENV{WEBHOOK_TOKEN};
my $log_file    = $ENV{LOG_FILE}     // './triggered.log';

unless ($token) {
    warn "[triggered] WARNING: WEBHOOK_TOKEN is not set — "
       . "/webhook and /reset are unauthenticated\n";
}

# hypnotoad listen (production mode)
app->config(hypnotoad => { listen => ["http://$host:$port"] });

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

my $color      = 'green';
my $clients    = {};
my $timer_id;
my $alert_time;   # epoch when alert was last triggered

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
    my $payload = encode_json({ color => $color, reset_in => reset_remaining() });
    for my $id (keys %$clients) {
        $clients->{$id}->write("data: $payload\n\n");
    }
}

sub arm_timer {
    Mojo::IOLoop->remove($timer_id) if $timer_id;
    $timer_id = Mojo::IOLoop->timer($reset_delay => sub {
        $color      = 'green';
        $alert_time = undef;
        $timer_id   = undef;
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

    $color      = 'red';
    $alert_time = time();
    arm_timer();
    notify_clients();
    app->log->info("Alert triggered via webhook");
    $c->render(json => { status => 'ok', color => $color, reset_in => $reset_delay });
};

# Manual reset
post '/reset' => sub {
    my $c = shift;
    return $c->render(json => { error => 'Unauthorized' }, status => 401)
        unless authorized($c);

    Mojo::IOLoop->remove($timer_id) if $timer_id;
    $timer_id   = undef;
    $color      = 'green';
    $alert_time = undef;
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

    my $payload = encode_json({ color => $color, reset_in => reset_remaining() });
    $c->write("data: $payload\n\n");
};

# Status page
get '/' => 'index';

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
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Visual Alert</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      display: flex;
      align-items: center;
      justify-content: center;
      height: 100vh;
      font-family: system-ui, sans-serif;
      background-color: green;
      transition: background-color 0.4s ease;
    }
    #panel {
      text-align: center;
      color: white;
      text-shadow: 0 1px 6px rgba(0,0,0,0.4);
      user-select: none;
    }
    #label {
      font-size: 5rem;
      font-weight: 700;
      letter-spacing: 0.05em;
    }
    #countdown {
      margin-top: 1rem;
      font-size: 1.4rem;
      opacity: 0.85;
      min-height: 2rem;
    }
    #conn-status {
      position: fixed;
      bottom: 1rem;
      right: 1rem;
      font-size: 0.8rem;
      opacity: 0.6;
      color: white;
    }
  </style>
</head>
<body>
  <div id="panel">
    <div id="label">OK</div>
    <div id="countdown"></div>
  </div>
  <div id="conn-status">connecting…</div>

  <script>
    var source           = new EventSource('/events');
    var countdownTimer   = null;
    var secondsRemaining = 0;

    source.onopen = function () {
      document.getElementById('conn-status').textContent = 'connected';
    };

    source.onmessage = function (e) {
      var data = JSON.parse(e.data);
      applyState(data.color, data.reset_in || 0);
    };

    source.onerror = function () {
      document.getElementById('conn-status').textContent = 'reconnecting…';
    };

    function applyState(color, resetIn) {
      document.body.style.backgroundColor = color;
      document.getElementById('label').textContent = color === 'red' ? 'ALERT' : 'OK';

      clearInterval(countdownTimer);
      countdownTimer = null;
      document.getElementById('countdown').textContent = '';

      if (color === 'red' && resetIn > 0) {
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

    function renderCountdown() {
      document.getElementById('countdown').textContent =
        'Auto-reset in ' + secondsRemaining + 's';
    }
  </script>
</body>
</html>
