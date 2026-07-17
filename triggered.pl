#!/usr/bin/env perl
# triggered.pl — visual alert server
# Requires: Mojolicious (cpanm --installdeps .)
# Perl >= 5.20 recommended
#
# Configuration (environment variables):
#   PORT              — listen port                        (default: 3000)
#   LISTEN_HOST       — bind address                      (default: 127.0.0.1)
#   RESET_DELAY       — auto-reset seconds                (default: 60)
#   WEBHOOK_TOKEN     — bearer token for auth             (default: unset = unauthenticated)
#   LOG_FILE          — path to log file                  (default: ./triggered.log)
#   ALERT_SOUND       — path to audio file (.mp3 .wav .ogg .m4a)
#
#   NOTIFY_URL        — outbound push URL (ntfy.sh / Slack / Discord / generic)
#   NOTIFY_ON_RESET   — set to 1 to also push on alert clear (default: 0)
#
#   CAMERA_ALLOW      — comma-separated allow-list (only these cameras alert)
#   CAMERA_IGNORE     — comma-separated ignore-list (these cameras are logged only)
#
#   QUIET_START       — quiet hours start HH:MM 24h local (e.g. 22:00)
#   QUIET_END         — quiet hours end   HH:MM 24h local (e.g. 07:00)
#                       During quiet hours alerts are amber (push still fires)
#
#   ALT_ALERTS_DIR    — folder of display overrides        (default: ./ALT_ALERTS)
#                       If <state>.png exists there (state = green | red |
#                       amber), the browser shows that image full-screen
#                       instead of the plain alert color. PNG only — HTML
#                       overrides were deliberately removed for security
#                       (no script execution surface). Other files ignored.
#                       Checked live — add/remove files without restarting.
#
#   SNAPSHOT_TTL      — seconds before snapshots expire   (default: 300)
#   SNAPSHOT_MAX_BYTES— max upload size per snapshot      (default: 2097152 = 2 MB)
#
# Endpoints:
#   GET  /               — alert page (SSE-driven, PWA-installable)
#   GET  /events         — Server-Sent Events stream
#   POST /webhook        — trigger alert; optional JSON body: {"camera":"name"}
#   POST /reset          — manually clear alert
#   GET  /api/history    — JSON array of last 100 alerts (newest first)
#   POST /snapshot       — receive camera snapshot image  (?camera=Name)
#   GET  /snapshot/:cam  — serve latest snapshot for a camera
#   GET  /api/snapshots  — JSON list of cameras with available snapshots
#   GET  /alert-sound    — serves the ALERT_SOUND file (if configured)
#   GET  /alt-alert/<state>.png — serves an ALT_ALERTS override (whitelisted names only)
#   GET  /manifest.json, /icon.svg, /sw.js — PWA assets
#
# Deploy behind a TLS-terminating reverse proxy (nginx, caddy) for HTTPS.

use 5.020;
use Mojolicious::Lite;
use Mojo::IOLoop;
use Mojo::JSON qw(encode_json);
use Mojo::Asset::File;
use Mojo::UserAgent;
use POSIX qw(strftime);

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

my $port        = $ENV{PORT}         // 3000;
my $host        = $ENV{LISTEN_HOST}  // '127.0.0.1';
my $reset_delay = $ENV{RESET_DELAY}  // 60;
my $token       = $ENV{WEBHOOK_TOKEN};
my $log_file    = $ENV{LOG_FILE}     // './triggered.log';
my $alert_sound = $ENV{ALERT_SOUND};

my $notify_url      = $ENV{NOTIFY_URL};
my $notify_on_reset = $ENV{NOTIFY_ON_RESET} // 0;

my $camera_allow_raw  = $ENV{CAMERA_ALLOW}  // '';
my $camera_ignore_raw = $ENV{CAMERA_IGNORE} // '';

my $quiet_start = $ENV{QUIET_START};   # e.g. "22:00"
my $quiet_end   = $ENV{QUIET_END};     # e.g. "07:00"

my $alt_dir     = $ENV{ALT_ALERTS_DIR} // './ALT_ALERTS';  # display-override folder

my $snapshot_ttl  = $ENV{SNAPSHOT_TTL}        // 300;
my $snapshot_max  = $ENV{SNAPSHOT_MAX_BYTES}  // 2_097_152;  # 2 MB
my $snapshot_cap  = 20;  # max number of distinct cameras to store

# Build camera filter lookup tables (lower-cased for case-insensitive match)
my %cam_allow  = map { lc($_) => 1 } grep { length } split /\s*,\s*/, $camera_allow_raw;
my %cam_ignore = map { lc($_) => 1 } grep { length } split /\s*,\s*/, $camera_ignore_raw;

if ($alert_sound && !-e $alert_sound) {
    warn "[triggered] WARNING: ALERT_SOUND file not found: $alert_sound\n";
    $alert_sound = undef;
}

unless ($token) {
    warn "[triggered] WARNING: WEBHOOK_TOKEN is not set — "
       . "/webhook, /reset and /snapshot are unauthenticated\n";
}

warn "[triggered] CAMERA_ALLOW filter: $camera_allow_raw\n"  if %cam_allow;
warn "[triggered] CAMERA_IGNORE filter: $camera_ignore_raw\n" if %cam_ignore;
warn "[triggered] Quiet hours: ${quiet_start}–${quiet_end}\n" if $quiet_start && $quiet_end;
warn "[triggered] ALT_ALERTS overrides folder: $alt_dir\n"    if -d $alt_dir;
warn "[triggered] Push notifications: $notify_url\n"          if $notify_url;

# hypnotoad listen (production mode)
app->config(hypnotoad => {
    listen   => ["http://$host:$port"],
    workers  => 1,
    pid_file => $ENV{TRIGGERED_PID_FILE} // '/tmp/triggered-hypnotoad.pid',
});

app->hook(before_server_start => sub {
    my ($server, $app) = @_;
    $server->listen(["http://$host:$port"])
        if $server->isa('Mojo::Server::Daemon');
});

app->log->path($log_file);
app->log->level('info');

my $DEBUG = $ENV{DEBUG} // 0;
app->log->level($DEBUG ? 'debug' : 'info');
sub dlog { app->log->debug(shift) if $DEBUG }

if ($DEBUG) {
    dlog("=== triggered.pl startup ===");
    dlog("PORT=$port  LISTEN_HOST=$host  RESET_DELAY=$reset_delay");
    dlog("LOG_FILE=$log_file");
    dlog("WEBHOOK_TOKEN=" . ($token ? "[REDACTED len=" . length($token) . "]" : "[unset]"));
    dlog("NOTIFY_URL=" . ($notify_url // '[unset]') . "  NOTIFY_ON_RESET=$notify_on_reset");
    dlog("CAMERA_ALLOW=" . ($camera_allow_raw || '[unset]') . "  CAMERA_IGNORE=" . ($camera_ignore_raw || '[unset]'));
    dlog("QUIET_START=" . ($quiet_start // '[unset]') . "  QUIET_END=" . ($quiet_end // '[unset]'));
    dlog("SNAPSHOT_TTL=$snapshot_ttl  SNAPSHOT_MAX_BYTES=$snapshot_max  SNAPSHOT_CAP=$snapshot_cap");
    dlog("ALERT_SOUND=" . ($alert_sound // '[unset]'));
}

# ---------------------------------------------------------------------------
# Shared state
# ---------------------------------------------------------------------------

my $color       = 'green';
my $clients     = {};
my $timer_id;
my $alert_time;
my $camera_name = '';
my $quiet_mode  = 0;   # 1 when current time falls within quiet hours

my @history   = ();    # ring buffer of last 100 alert records
my %snapshots = ();    # camera_name => { data, mime, ts }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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

# Return Unix epoch when current quiet period ends (undef if not in quiet hours)
sub quiet_until_epoch {
    return undef unless $quiet_mode && $quiet_end;
    my ($end_h, $end_m) = split /:/, $quiet_end;
    my @t = localtime(time());
    my $end_epoch = POSIX::mktime(0, int($end_m), int($end_h), $t[3], $t[4], $t[5]);
    $end_epoch += 86400 if $end_epoch <= time();  # end already passed today → tomorrow
    return $end_epoch;
}

# Return 1 if the current local time falls within [QUIET_START, QUIET_END)
sub in_quiet_hours {
    return 0 unless $quiet_start && $quiet_end;
    my $now = strftime('%H:%M', localtime(time()));
    my $result;
    if ($quiet_start le $quiet_end) {
        $result = ($now ge $quiet_start && $now lt $quiet_end) ? 1 : 0;
    } else {
        # Wraps midnight (e.g. 22:00 – 07:00)
        $result = ($now ge $quiet_start || $now lt $quiet_end) ? 1 : 0;
    }
    dlog("in_quiet_hours: now=$now start=$quiet_start end=$quiet_end => $result");
    return $result;
}

# Return 1 if a camera name is permitted to trigger an alert
sub camera_allowed {
    my $cam = lc(shift // '');
    return 0 if %cam_ignore && $cam_ignore{$cam};
    return 1 unless %cam_allow;
    return $cam_allow{$cam} ? 1 : 0;
}

# Sanitise a camera name for use as a URL segment / hash key
sub sanitise_camera {
    my $cam = shift // '';
    $cam =~ s/[^A-Za-z0-9_\-\s]//g;
    $cam =~ s/\s+/ /g;
    $cam = substr($cam, 0, 64);
    $cam =~ s/^\s+|\s+$//g;
    return $cam;
}

# Extract camera name from the request body — tolerates three real-world formats:
#   1. Valid JSON:          {"camera":"Front Door"}
#   2. Plain text key:val:  camera:Livingroom (Blue Iris default)
#   3. URL query parameter: POST /webhook?camera=Front+Door
sub extract_camera {
    my $c = shift;

    my $json = eval { $c->req->json };
    if ($json && ref $json eq 'HASH' && length($json->{camera} // '')) {
        return $json->{camera};
    }

    my $raw = $c->req->body // '';
    $raw =~ s/\A\s+|\s+\z//g;
    $raw =~ s/\A['"](.+)['"]\z/$1/s;
    return $1 if $raw =~ /\Acamera\s*:\s*(.+)\z/i;

    return $c->req->param('camera') // '';
}

# ---- ALT_ALERTS display overrides -----------------------------------------

# Map the current server state to its display name.
# quiet wins over everything (matches the front-end's precedence),
# otherwise it's the plain alert color: 'green' or 'red'.
sub effective_state {
    return $quiet_mode ? 'amber' : $color;
}

# Look for an override image for a given state (green|red|amber).
# WHY: lets the user drop in a custom image instead of the flat color.
# PNG ONLY by deliberate security decision — HTML overrides would execute
# arbitrary script in every viewer's browser; images have no such surface.
# Returns a hashref { type, url } or undef if no override exists.
# The file's mtime is appended as ?v= so browsers re-fetch edited files
# instead of serving a stale cached copy.
sub alt_alert_info {
    my $state = shift;
    return undef unless $state =~ /^(?:green|red|amber)$/;  # safety: never build paths from other input
    my $path = "$alt_dir/$state.png";
    return undef unless -f $path;
    my $mtime = (stat($path))[9] // 0;
    return { type => 'png', url => "/alt-alert/$state.png?v=$mtime" };
}

# Signature of all override files (name + mtime). Used by the recurring
# scanner to detect adds/removes/edits so we only broadcast on real change.
sub alt_alerts_signature {
    my @sig;
    for my $state (qw(green red amber)) {
        my $path = "$alt_dir/$state.png";
        push @sig, "$state.png=" . ((stat($path))[9] // 0) if -f $path;
    }
    return join(';', @sig);
}

# ---------------------------------------------------------------------------

# Build the state payload shared by SSE broadcasts and the /events handshake.
# Kept in one place so the two can never drift apart.
sub state_payload {
    return encode_json({
        color       => $color,
        reset_in    => reset_remaining(),
        camera      => $camera_name,
        quiet       => $quiet_mode ? \1 : \0,
        quiet_until => quiet_until_epoch(),
        alt         => alt_alert_info(effective_state()),  # null when no override
    });
}

# Broadcast current state to all SSE clients
sub notify_clients {
    my $payload = state_payload();
    dlog("notify_clients: count=" . scalar(keys %$clients) . " payload=$payload");
    for my $id (keys %$clients) {
        $clients->{$id}->write("data: $payload\n\n");
    }
}

# Arm (or re-arm) the auto-reset countdown timer
sub arm_timer {
    my %opts = @_;
    dlog("arm_timer: arming delay=${reset_delay}s" . ($timer_id ? " replacing=$timer_id" : ""));
    Mojo::IOLoop->remove($timer_id) if $timer_id;
    $timer_id = Mojo::IOLoop->timer($reset_delay => sub {
        dlog("arm_timer: fired — auto-resetting");
        # Record duration on the current open history entry
        if (@history && !defined $history[-1]{cleared_at}) {
            $history[-1]{cleared_at} = time();
            $history[-1]{cleared_by} = 'auto';
            $history[-1]{duration}   = time() - $history[-1]{ts};
        }
        $color       = 'green';
        $alert_time  = undef;
        $timer_id    = undef;
        $camera_name = '';
        notify_clients();
        app->log->info('Alert auto-reset');
        send_notification('Alert cleared (auto-reset)', '') if $notify_on_reset && $notify_url;
    });
    dlog("arm_timer: new timer_id=$timer_id");
}

# Fire-and-forget outbound push notification (non-blocking)
sub send_notification {
    my ($msg, $cam) = @_;
    return unless $notify_url;
    dlog("send_notification: url=$notify_url msg=$msg cam=" . ($cam // ''));

    my $ua = Mojo::UserAgent->new;
    $ua->connect_timeout(5)->request_timeout(10);

    my $tx;
    if ($notify_url =~ m|ntfy\.sh|i) {
        my $title = $cam ? "Alert – $cam" : 'Visual Alert';
        $tx = $ua->post($notify_url => {
            'X-Title'    => $title,
            'X-Message'  => $msg,
            'X-Priority' => 'high',
            'X-Tags'     => 'rotating_light',
        } => '');
    } elsif ($notify_url =~ m|slack|i || $notify_url =~ m|discord|i) {
        $tx = $ua->post($notify_url => json => { text => $msg });
    } else {
        $tx = $ua->post($notify_url => json => {
            alert  => $msg,
            camera => $cam // '',
            ts     => time(),
        });
    }

    if ($tx && $tx->result->is_error) {
        app->log->warn("Push notification failed: " . $tx->result->message);
        dlog("send_notification: FAILED status=" . $tx->result->code . " body=" . $tx->result->body);
    } else {
        dlog("send_notification: OK status=" . ($tx ? $tx->result->code : 'n/a'));
    }
}

# ---------------------------------------------------------------------------
# Timers
# ---------------------------------------------------------------------------

# SSE heartbeat — keeps connections alive through proxies
Mojo::IOLoop->recurring(30 => sub {
    for my $id (keys %$clients) {
        $clients->{$id}->write(": ping\n\n");
    }
});

# Quiet hours — re-evaluate every 60 s and broadcast if mode changes
$quiet_mode = in_quiet_hours();
Mojo::IOLoop->recurring(60 => sub {
    my $prev = $quiet_mode;
    $quiet_mode = in_quiet_hours();
    if ($prev != $quiet_mode) {
        dlog("quiet_hours_check: mode changed prev=$prev new=$quiet_mode — broadcasting");
        notify_clients();
    }
});

# ALT_ALERTS — re-scan every 5 s so dropping in / removing / editing an
# override file takes effect live without a restart or a state change.
# WHY a signature compare: 6 stat() calls are cheap; broadcasting on every
# tick is not. We only push to clients when the file set actually changed.
my $alt_sig = alt_alerts_signature();
Mojo::IOLoop->recurring(5 => sub {
    my $sig = alt_alerts_signature();
    if ($sig ne $alt_sig) {
        dlog("alt_alerts_check: change detected ('$alt_sig' -> '$sig') — broadcasting");
        $alt_sig = $sig;
        notify_clients();
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

    my $cam = extract_camera($c);
    dlog("/webhook: body=" . substr($c->req->body // '', 0, 256));
    dlog("/webhook: camera='$cam'");

    # Camera filtering
    unless (camera_allowed(lc($cam))) {
        my $reason = %cam_ignore && $cam_ignore{lc($cam)} ? 'ignore-list' : 'not in allow-list';
        dlog("/webhook: suppressed camera='$cam' reason=$reason");
        app->log->info("Webhook suppressed — camera '$cam' on $reason");
        return $c->render(json => { status => 'suppressed', camera => $cam });
    }

    # Quiet hours: record in history and log, but make no display or audio change
    if ($quiet_mode) {
        my $cam_info = $cam ? " (camera: $cam)" : '';
        dlog("/webhook: quiet hours — logging only${cam_info}");
        app->log->info("Alert suppressed — quiet hours${cam_info}");
        push @history, {
            camera     => $cam,
            ts         => time(),
            cleared_at => time(),
            cleared_by => 'quiet',
            duration   => undef,
        };
        shift @history if @history > 100;
        return $c->render(json => { status => 'suppressed', reason => 'quiet hours', camera => $cam });
    }

    dlog("/webhook: ALERT prev_color=$color");
    $camera_name = $cam;
    $color       = 'red';
    $alert_time  = time();
    arm_timer();
    notify_clients();

    # History: close any previously unclosed entry (rapid re-trigger before auto-reset)
    if (@history && !defined $history[-1]{cleared_at}) {
        $history[-1]{cleared_at} = time();
        $history[-1]{cleared_by} = 'replaced';
        $history[-1]{duration}   = time() - $history[-1]{ts};
    }

    # History: push new entry (cap at 100)
    push @history, {
        camera     => $camera_name,
        ts         => $alert_time,
        cleared_at => undef,
        cleared_by => undef,
        duration   => undef,
    };
    shift @history if @history > 100;

    my $cam_info = $camera_name ? " (camera: $camera_name)" : '';
    app->log->info("Alert triggered via webhook${cam_info}");

    if ($notify_url) {
        my $notif_cam = $camera_name;
        my $notif_msg = $camera_name ? "Alert – $camera_name" : 'Alert triggered';
        Mojo::IOLoop->timer(0 => sub { send_notification($notif_msg, $notif_cam) });
    }

    $c->render(json => {
        status   => 'ok',
        color    => $color,
        reset_in => $reset_delay,
        camera   => $camera_name,
        quiet    => \0,
    });
};

# Manual reset
post '/reset' => sub {
    my $c = shift;
    return $c->render(json => { error => 'Unauthorized' }, status => 401)
        unless authorized($c);

    dlog("/reset: manual reset camera_was='$camera_name' color_was=$color");
    Mojo::IOLoop->remove($timer_id) if $timer_id;
    $timer_id   = undef;

    # Record duration on the current open history entry
    if (@history && !defined $history[-1]{cleared_at}) {
        $history[-1]{cleared_at} = time();
        $history[-1]{cleared_by} = 'manual';
        $history[-1]{duration}   = time() - $history[-1]{ts};
    }

    $color      = 'green';
    $alert_time = undef;
    dlog("/reset: cleared, broadcasting to " . scalar(keys %$clients) . " clients");
    notify_clients();

    my $cam_info = $camera_name ? " (camera: $camera_name)" : '';
    app->log->info("Alert manually reset${cam_info}");

    if ($notify_url && $notify_on_reset) {
        my $notif_cam = $camera_name;
        Mojo::IOLoop->timer(0 => sub { send_notification('Alert cleared (manual reset)', $notif_cam) });
    }

    $c->render(json => { status => 'ok', color => $color });
};

# SSE stream — sends current state immediately on connect, then pushes updates
get '/events' => sub {
    my $c = shift;
    $c->inactivity_timeout(300);

    my $stream = Mojo::IOLoop->stream($c->tx->connection);
    my $id     = $c->tx->connection;
    $clients->{$id} = $stream;
    dlog("/events: connect id=$id total=" . scalar(keys %$clients));
    $stream->on(close => sub {
        dlog("/events: disconnect id=$id remaining=" . (scalar(keys %$clients) - 1));
        delete $clients->{$id};
    });

    $c->res->headers->content_type('text/event-stream');
    $c->res->headers->cache_control('no-cache');
    $c->res->headers->header('Access-Control-Allow-Origin' => '*');

    # Same payload as broadcasts — built by state_payload() so a client
    # connecting mid-state (incl. an active ALT_ALERTS override) is correct.
    $c->write("data: " . state_payload() . "\n\n");
};

# Alert history (newest first, last 100 events)
get '/api/history' => sub {
    my $c = shift;
    $c->res->headers->header('Access-Control-Allow-Origin' => '*');
    $c->res->headers->cache_control('no-cache');
    $c->render(json => [reverse @history]);
};

# Receive a camera snapshot image from Blue Iris (or any HTTP client)
post '/snapshot' => sub {
    my $c = shift;
    return $c->render(json => { error => 'Unauthorized' }, status => 401)
        unless authorized($c);

    my $cam  = sanitise_camera($c->req->param('camera') // '');
    my $body = $c->req->body // '';
    my $size = length($body);

    return $c->render(json => { error => 'camera parameter required' }, status => 400)
        unless length($cam);

    return $c->render(json => { error => 'Payload too large' }, status => 413)
        if $size > $snapshot_max;

    my $mime = $c->req->headers->content_type // 'image/jpeg';
    $mime = 'image/jpeg' unless $mime =~ m{^image/};

    dlog("/snapshot: camera='$cam' size=$size mime=$mime");

    # Evict oldest camera entry if cap reached
    if (!exists $snapshots{$cam} && scalar(keys %snapshots) >= $snapshot_cap) {
        my ($oldest) = sort { $snapshots{$a}{ts} <=> $snapshots{$b}{ts} } keys %snapshots;
        delete $snapshots{$oldest};
        dlog("/snapshot: evicted '$oldest' (cap=$snapshot_cap)");
        app->log->warn("Snapshot camera cap ($snapshot_cap) reached — evicted: $oldest");
    }

    $snapshots{$cam} = { data => $body, mime => $mime, ts => time() };
    dlog("/snapshot: stored ok total=" . scalar(keys %snapshots));
    app->log->info("Snapshot stored: $cam ($size bytes)");

    $c->render(json => { status => 'ok', camera => $cam, bytes => $size });
};

# Serve latest snapshot for a camera
get '/snapshot/:camera' => sub {
    my $c   = shift;
    my $cam = sanitise_camera($c->param('camera'));
    my $snap = $snapshots{$cam};

    return $c->reply->not_found unless $snap;

    if (time() - $snap->{ts} > $snapshot_ttl) {
        delete $snapshots{$cam};
        return $c->reply->not_found;
    }

    $c->res->headers->content_type($snap->{mime});
    $c->res->headers->cache_control('no-cache, no-store');
    $c->res->headers->header('Access-Control-Allow-Origin' => '*');
    $c->res->headers->header('X-Snapshot-Ts'              => $snap->{ts});
    $c->render(data => $snap->{data});
};

# List cameras that have a live (non-expired) snapshot
get '/api/snapshots' => sub {
    my $c = shift;
    $c->res->headers->header('Access-Control-Allow-Origin' => '*');
    my $now = time();
    my @live = grep { $now - $snapshots{$_}{ts} <= $snapshot_ttl } keys %snapshots;
    # Sort: active alert camera first, then alphabetical
    @live = sort {
        ($b eq $camera_name) <=> ($a eq $camera_name) || $a cmp $b
    } @live;
    $c->render(json => { cameras => \@live });
};

# Status page
get '/' => sub {
    my $c = shift;
    $c->stash(sound_url => $alert_sound ? '/alert-sound' : '');
    $c->render('index');
};

# Serve audio file
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

# Serve an ALT_ALERTS override image.
# SECURITY: the filename must match the exact whitelist (green|red|amber
# + .png). Everything else 404s, so ../ traversal or serving of arbitrary
# files from the folder is impossible by construction. PNG only — .html
# support was deliberately removed to eliminate script execution.
# NOTE: '#file' (relaxed placeholder) not ':file' — the standard placeholder
# stops at '.', so 'green.png' would arrive as file='green' + format='png'
# and always fail the whitelist. '#' matches everything except '/'.
get '/alt-alert/#file' => sub {
    my $c    = shift;
    my $file = $c->param('file');
    return $c->reply->not_found
        unless $file =~ /^(?:green|red|amber)\.png$/;
    my $path = "$alt_dir/$file";
    return $c->reply->not_found unless -f $path;
    $c->res->headers->content_type('image/png');
    # no-cache: the ?v=mtime cache-buster handles freshness; this prevents
    # a proxy pinning an old copy under the same URL.
    $c->res->headers->cache_control('no-cache');
    $c->reply->asset(Mojo::Asset::File->new(path => $path));
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

# PWA — app icon
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

# PWA — service worker
get '/sw.js' => sub {
    my $c = shift;
    $c->res->headers->content_type('application/javascript');
    $c->render(text => <<'END_SW');
const CACHE = 'visual-alert-v1';
// /alt-alert must bypass the SW cache — overrides are live files on disk
const BYPASS = ['/events', '/webhook', '/reset', '/snapshot', '/alert-sound', '/alt-alert', '/api/'];

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

    /* ALT_ALERTS override overlay.
       Sits above the color panel (z-index 5) but below #controls (z-index 10)
       so the sound/connection controls stay usable over a custom display. */
    #alt-overlay {
      position: fixed;
      inset: 0;
      z-index: 5;
      display: none;
    }
    #alt-overlay.active { display: block; }
    #alt-overlay img {
      width: 100%;
      height: 100%;
      display: block;
      /* Full-screen cover: fill viewport, preserve aspect, crop edges */
      object-fit: cover;
    }

    #controls { z-index: 10; }
  </style>
</head>
<body>
  <div id="panel">
    <div id="label">OK</div>
    <div id="camera"></div>
    <div id="countdown"></div>
  </div>

  <!-- ALT_ALERTS override display (filled by JS when the server reports one) -->
  <div id="alt-overlay"></div>

  <div id="controls">
    <span id="conn-status">connecting…</span>
    % if ($sound_url) {
    <button class="ctrl-btn" id="sound-btn" title="Toggle sound">🔊</button>
    % }
  </div>

  <script>
    var SOUND_URL = '<%== $sound_url %>';

    var audio       = SOUND_URL ? new Audio(SOUND_URL) : null;
    var soundMuted  = false;
    var audioUnlocked = false;

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

    var source           = new EventSource('/events');
    var countdownTimer   = null;
    var secondsRemaining = 0;
    var quietTimer       = null;
    var quietRemaining   = 0;
    var currentColor     = 'green';  // logical alert color: 'green' | 'red'

    source.onopen = function () {
      document.getElementById('conn-status').textContent = 'connected';
    };

    source.onmessage = function (e) {
      var data = JSON.parse(e.data);
      applyState(data.color, data.reset_in || 0, data.camera || '', data.quiet || false, data.quiet_until || 0, data.alt || null);
    };

    source.onerror = function () {
      document.getElementById('conn-status').textContent = 'reconnecting…';
    };

    // ALT_ALERTS override handling ---------------------------------------
    var altOverlay    = document.getElementById('alt-overlay');
    var currentAltUrl = null;   // URL of the override currently displayed

    // alt = { type: 'png', url: '/alt-alert/<state>.png?v=<mtime>' }
    // or null when no override file exists for the current state.
    // PNG only — HTML overrides were deliberately removed (security:
    // no script execution surface on the alert display).
    function applyAltOverride(alt) {
      if (!alt) {
        // No override — clear the overlay so the plain color shows again
        if (currentAltUrl !== null) {
          altOverlay.classList.remove('active');
          altOverlay.innerHTML = '';
          currentAltUrl = null;
        }
        return;
      }
      // WHY compare URLs: the server pushes full state on every SSE event;
      // rebuilding the img each time would flicker. The ?v=mtime in the
      // URL also means an edited file gets a new URL and is reloaded.
      if (alt.url === currentAltUrl) return;
      currentAltUrl = alt.url;
      altOverlay.innerHTML = '';
      var el = document.createElement('img');
      el.src = alt.url;
      el.alt = 'alert display override';
      altOverlay.appendChild(el);
      altOverlay.classList.add('active');
    }
    // --------------------------------------------------------------------

    function applyState(color, resetIn, camera, quiet, quietUntil, alt) {
      var wasAlertActive = (currentColor === 'red');
      currentColor = color;

      // Show/hide the ALT_ALERTS override first; the normal color logic
      // below still runs so sound, countdowns and theme-color keep working.
      applyAltOverride(alt);

      var bgColor =
        quiet           ? '#b45309' :
        color === 'red' ? '#dc2626' : '#15803d';

      document.body.style.backgroundColor = bgColor;
      document.getElementById('theme-meta').setAttribute('content', bgColor);

      document.getElementById('label').textContent =
        quiet           ? 'QUIET' :
        color === 'red' ? 'ALERT' : 'OK';

      document.getElementById('camera').textContent =
        (color === 'red' && camera) ? camera : '';

      clearInterval(countdownTimer);
      countdownTimer   = null;
      secondsRemaining = 0;
      clearInterval(quietTimer);
      quietTimer     = null;
      quietRemaining = 0;
      document.getElementById('countdown').textContent = '';

      if (color === 'red') {
        if (!wasAlertActive) playAlert();
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
      } else if (quiet && quietUntil) {
        quietRemaining = Math.max(0, Math.round(quietUntil - Date.now() / 1000));
        if (quietRemaining > 0) {
          renderQuietCountdown();
          quietTimer = setInterval(function () {
            quietRemaining--;
            if (quietRemaining <= 0) {
              clearInterval(quietTimer);
              quietTimer = null;
              document.getElementById('countdown').textContent = '';
            } else {
              renderQuietCountdown();
            }
          }, 1000);
        }
      }
    }

    function renderCountdown() {
      document.getElementById('countdown').textContent =
        'Auto-reset in ' + secondsRemaining + 's';
    }

    function renderQuietCountdown() {
      var h = Math.floor(quietRemaining / 3600);
      var m = Math.floor((quietRemaining % 3600) / 60);
      var s = quietRemaining % 60;
      document.getElementById('countdown').textContent = h > 0
        ? 'Quiet ends in ' + h + 'h ' + pad2(m) + 'm'
        : m > 0
        ? 'Quiet ends in ' + m + 'm ' + pad2(s) + 's'
        : 'Quiet ends in ' + s + 's';
    }

    function pad2(n) { return n < 10 ? '0' + n : '' + n; }

    if ('serviceWorker' in navigator) {
      navigator.serviceWorker.register('/sw.js').catch(function () {});
    }
  </script>
</body>
</html>
