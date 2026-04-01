#!/usr/bin/env perl

use Mojolicious::Lite;
use Mojo::IOLoop;

app->config(hypnotoad => {listen => ['http://*:3000']});

# Shared state
my $color = 'green';
my $clients = {};
my $timer_id;  # Timer ID for the 60-second interval

# Function to notify clients about color change
sub notify_clients {
    for my $id (keys %$clients) {
        $clients->{$id}->write("data: $color\n\n");
    }
}

# Function to reset the timer
sub reset_timer {
    # Remove existing timer if it exists
    Mojo::IOLoop->remove($timer_id) if $timer_id;

    # Start a new timer
    $timer_id = Mojo::IOLoop->timer(60 => sub {
        $color = 'green';
        notify_clients();
    });
}

# Webhook route
post '/webhook' => sub {
    my $c = shift;
    $color = 'red';
    reset_timer();
    notify_clients();
    $c->render(text => 'Webhook received');
};

# SSE route
get '/events' => sub {
    my $c = shift;
    $c->inactivity_timeout(300);

    # Stream setup
    my $stream = Mojo::IOLoop->stream($c->tx->connection);
    my $id = $c->tx->connection;
    $clients->{$id} = $stream;
    $stream->on(close => sub {
        delete $clients->{$id};
    });

    $c->res->headers->content_type('text/event-stream');
    $c->write("data: $color\n\n");
};

# Home route
get '/' => 'index';

app->start;
__DATA__

@@ index.html.ep
<!DOCTYPE html>
<html>
  <head>
    <title>Color State</title>
    <script type="text/javascript">
      var source = new EventSource('/events');
      source.onmessage = function(e) {
        document.body.style.backgroundColor = e.data;
      };
    </script>
  </head>
  <body>
  </body>
</html>

