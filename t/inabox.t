use v5.24.0;
use warnings;
use experimental 'signatures';

use lib 'lib', 't/lib';

use Future;
use IO::Async::Test;
use JSON::MaybeXS qw(encode_json);
use Plack::Response;
use Sub::Override;
use Test::More;
use Test::Deep;

use Synergy::Logger::Test '$Logger';
use Synergy::Reactor::InABox;
use Synergy::Tester;

# I'm not actually using this to do any testing, but it's convenient to set up
# users.
my $result = Synergy::Tester->testergize({
  reactors => {
    inabox => {
      class                  => 'Synergy::Reactor::InABox',
      box_domain             => 'fm.local',
      vpn_config_file        => '',
      digitalocean_api_token => '1234',
    },
  },
  default_from => 'alice',
  users => {
    alice   => undef,
    bob => undef,
  },
  todo => [],
});

# Set up a bunch of nonsense
local $Logger = $result->logger;
my $s = $result->synergy;
my $channel = $s->channel_named('test-channel');

# Fake up responses from VO.
my @DO_RESPONSES;
my $DO_RESPONSE = gen_response(200, {});
$s->server->register_path('/do', sub {
  return shift @DO_RESPONSES if @DO_RESPONSES;
  return $DO_RESPONSE;
});
my $url = sprintf("http://localhost:%s/do", $s->server->server_port);

# Muck with the guts of VO reactor to catch our fakes.
my $endpoint = Sub::Override->new(
  'Synergy::Reactor::InABox::_do_endpoint',
  sub { return $url },
);


# dumb convenience methods
sub gen_response ($code, $data) {
  my $json = encode_json($data);
  return Plack::Response->new($code, [], $json)->finalize;
}

sub send_message ($text, $from = $channel->default_from) {
  $channel->queue_todo([ send => { text => $text, from => $from }  ]);
  $channel->queue_todo([ wait => {} ]);
  wait_for { $channel->is_exhausted; };
}

sub single_message_text {
  my @texts = map {; $_->{text} } $channel->sent_messages;
  fail("expected only one message, but got " . @texts) if @texts > 1;
  $channel->clear_messages;
  return $texts[0];
}

# ok, let's test.

# minimal data for _format_droplet
my $alice_droplet = {
  id     => 123,
  name   => 'alice.box.fm.local',
  status => 'active',
  image  => {
    name => 'fminabox-20200202'
  },
  region => {
    name => 'Bridgewater',
    slug => 'bnj1',
  },
  networks => {
    v4 => [{ ip_address => '127.0.0.2' }],
  },
};

subtest 'status' => sub {
  # alice has a box, bob has none
  $DO_RESPONSE = gen_response(200, { droplets => [ $alice_droplet ] });

  send_message('synergy: box status');
  like(
    single_message_text(),
    qr{Your box: name: \Qalice.box.fm.local\E},
    'alice has a box and synergy says so'
  );

  send_message('synergy: box status', 'bob');
  is(
    single_message_text(),
    "You don't seem to have a box.",
    'bob has no box and synergy says so'
  );
};

# the above has confirmed that we can talk to DO and get the box, so now we'll
# just fake that method up.
our $droplet_guard = Sub::Override->new(
  'Synergy::Reactor::InABox::_get_droplet_for',
  sub { return Future->done($alice_droplet) },
);

subtest 'poweron' => sub {
  # already on
  send_message('synergy: box poweron');
  is(
    single_message_text(),
    'Your box is already powered on!',
    'if the box is already on, synergy says so'
  );

  # now off
  local $alice_droplet->{status} = 'off';
  @DO_RESPONSES = (
    gen_response(200, { action => { id => 987 } }),
    gen_response(200, { action => { status => 'completed'   } }),
  );

  send_message('synergy: box poweron');

  my @texts = map {; $_->{text} } $channel->sent_messages;
  is(@texts, 3, 'sent three messages (reactji on/off, and message)')
    or diag explain \@texts;

  is($texts[2], 'Your box has been powered on.', 'successfully turned on');

  $channel->clear_messages;
};

for my $method (qw(poweroff shutdown)) {
  subtest $method => sub {
    @DO_RESPONSES = (
      gen_response(200, { action => { id => 987 } }),
      gen_response(200, { action => { status => 'completed'   } }),
    );

    send_message("synergy: box $method");

    my @texts = map {; $_->{text} } $channel->sent_messages;
    is(@texts, 3, 'sent three messages (reactji on/off, and message)')
      or diag explain \@texts;

    like(
      $texts[2],
      qr{Your box has been (powered off|shut down)},
      'successfully turned off',
    );

    $channel->clear_messages;

    # already off
    local $alice_droplet->{status} = 'off';
    send_message("synergy: box $method");
    like(
      single_message_text(),
      qr{Your box is already (powered off|shut down)!},
      'if the box is already off, synergy says so'
    );
  };
}

subtest 'destroy' => sub {
  send_message('synergy: box destroy');
  like(
    single_message_text(),
    qr{powered on.*use /force to destroy it},
    'box is on, synergy suggests /force'
  );

  send_message('synergy: box destroy /force');
  is(single_message_text(), 'Box destroyed.', 'successfully force destroyed');

  local $alice_droplet->{status} = 'off';
  send_message('synergy: box destroy');
  is(single_message_text(), 'Box destroyed.', 'already off: successfully destroyed');
};

my %CREATE_RESPONSES = (
  first_droplet_fetch => gen_response(200, {
    droplets => []
  }),

  snapshot_fetch => gen_response(200, {
    snapshots => [{
      id => 42,
      name => 'fminabox-jessie-20200202',
    }]
  }),

  ssh_key_fetch => gen_response(200, {
    ssh_keys => [{
      name => 'fminabox',
      id => 99,
    }],
  }),

  droplet_create => gen_response(201, {
    droplet => { id => 8675309 },
    links => {
      actions => [{ id => 215 }],
    },
  }),

  action_fetch => gen_response(200, {
    action => { status => 'completed' }
  }),

  last_droplet_fetch => gen_response(200, {
    droplets => [ $alice_droplet ],
  }),

  dns_fetch => gen_response(200, {}),
  dns_post  => gen_response(200, {}),
);

subtest 'create' => sub {
  undef $droplet_guard;

  my $do_create = sub (%override) {
    my $resp_for = sub ($key) { $override{$key} // $CREATE_RESPONSES{$key} };
    my $msg = $override{message} // "box create";

    @DO_RESPONSES = (
      $resp_for->('first_droplet_fetch'),
      $resp_for->('snapshot_fetch'),
      $resp_for->('ssh_key_fetch'),
      $resp_for->('droplet_create'),
      $resp_for->('action_fetch'),
      $resp_for->('last_droplet_fetch'),
      $resp_for->('dns_fetch'),
      $resp_for->('dns_post'),
    );

    send_message("synergy: $msg");

    my @texts = map {; $_->{text} } $channel->sent_messages;
    $channel->clear_messages;
    return @texts;
  };

  subtest 'already have a box' => sub {
    my @texts = $do_create->(
      first_droplet_fetch => $CREATE_RESPONSES{last_droplet_fetch},
    );

    is(@texts, 1, 'sent a single failure message');
    like($texts[0], qr{already have a box}, 'message seems ok');
  };

  subtest 'good create' => sub {
    my @texts = $do_create->();
    is(@texts, 2, 'sent two messages: please hold, then completion');
    cmp_deeply(
      \@texts,
      [
        re(qr{Creating \w+ box in nyc3}),
        re(qr{Box created: name: \Qalice.box.fm.local\E}),
      ],
      'normal create with defaults seems fine'
    );
  };

  subtest 'bad snapshot / ssh key' => sub {
    # This is racy, because Future->needs_all fails immediately with the first
    # failure, and depending on what order the reactor decides to fire off the
    # requests in, it might get one before the other. That's fine, I think,
    # because all we care about is that there's some useful message.
    my @texts = $do_create->(
      snapshot_fetch => gen_response(200 => { snapshots => [] }),
    );

    is(@texts, 1, 'sent a single failure message');
    like($texts[0], qr{find a DO (snapshot|ssh key)}, 'no snapshot, message ok');

    @texts = $do_create->(
      ssh_key_fetch => gen_response(200 => { ssh_keys => [] }),
    );

    is(@texts, 1, 'sent a single failure message');
    like($texts[0], qr{find a DO (snapshot|ssh key)}, 'no ssh key, message ok');
  };

  subtest 'failed create' => sub {
    my @texts = $do_create->(droplet_create => gen_response(200 => {}));
    is(@texts, 2, 'sent two messages');
    cmp_deeply(
      \@texts,
      [
        re(qr{Creating \w+ box}),
        re(qr{There was an error creating the box}),
      ],
      'sent one will create, one error'
    );
  };

  subtest 'failed action fetch' => sub {
    my @texts = $do_create->(action_fetch => gen_response(200 => {
      action => { status => 'errored' },
    }));
    cmp_deeply(
      \@texts,
      [
        re(qr{Creating \w+ box}),
        re(qr{Something went wrong while creating box}),
      ],
      'sent one will create, one error'
    );
  };

  subtest 'good create with non-default version' => sub {
    my @texts = $do_create->(
      message => 'box create /version foo',
      snapshot_fetch => gen_response(200, {
        snapshots => [{
          id => 42,
          name => 'fminabox-foo-20201004',
        }]
      }),
    );

    cmp_deeply(
      \@texts,
      [
        re(qr{Creating \w+ box in nyc3}),
        re(qr{Box created: name: \Qalice.box.fm.local\E}),
      ],
      'got our two normal messages'
    );
  };
};

done_testing;
