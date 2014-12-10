#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Async::HTTP 0.02; # ->GET

use HTTP::Response;

use Net::Async::Matrix;

my $ua = Test::Async::HTTP->new;

my @rooms;
my $matrix = Net::Async::Matrix->new(
   ua => $ua,
   server => "localserver.test",

   on_room_new => sub {
      push @rooms, $_[1];
   },
);

my $login_f = $matrix->login(
   user_id => '@my-test-user:localserver.test',
   access_token => "0123456789ABCDEF",
);

ok( my $p = $ua->next_pending, '->start sends an HTTP request' );

my $uri = $p->request->uri;

is( $uri->authority, "localserver.test",                   '$req->uri->authority' );
is( $uri->path,      "/_matrix/client/api/v1/initialSync", '$req->uri->path' );
is_deeply(
   { $uri->query_form },
   { access_token => "0123456789ABCDEF", limit => 0 },
   '$req->uri->query_form' );

$p->respond( HTTP::Response->new( 200, "OK", [ "Content-Type" => "application/json" ], <<'EOJSON' ) );
{
   "end": "next_token_here",
   "presence": [ ],
   "rooms": [
      {
         "membership": "join",
         "room_id": "an-id-for-a-room",
         "messages": { },
         "state": [ ]
      }
   ]
}
EOJSON

ok( $login_f->is_ready, '->login ready after initial sync' );

ok( $matrix->start->is_ready, '->start is already ready' );

is( scalar @rooms, 1, '@rooms has a room object' );

is( $rooms[0]->room_id, "an-id-for-a-room", '$rooms[0]->room_id' );

done_testing;
