#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Async::HTTP 0.02; # ->GET

use HTTP::Response;

use Net::Async::Matrix;

my $ua = Test::Async::HTTP->new;

my $matrix = Net::Async::Matrix->new(
   ua => $ua,
   server => "localserver.test",

   on_error => sub {},
);

# Fail the first one
{
   my $login_f = $matrix->login(
      user_id => '@my-test-user:localserver.test',
      access_token => "0123456789ABCDEF",
   );

   my $start_f = $matrix->start;

   my $p = $ua->next_pending;
   $p->fail( "Server doesn't want to", http => undef, $p->request );

   ok( $login_f->is_ready, '->login is ready' );

   # Start is ready but failed
   ok( $start_f->is_ready, '->start is ready' );
   ok( $start_f->failure, '->start failed' );
}

# Second should still be attempted
{
   my $start_f = $matrix->start;

   ok( !$start_f->is_ready, 'Second ->start is not yet ready' );

   my $p = $ua->next_pending;
   ok( $p, 'Second request is made' );

   is( $p->request->uri->path, "/_matrix/client/api/v1/initialSync", 'Second request URI' );

   $p->respond( HTTP::Response->new( 200, "OK", [ "Content-Type" => "application/json" ], <<EOJSON ) );
{
   "end": "next_token_here",
   "presence": [],
   "rooms": []
}
EOJSON

   ok( $start_f->is_ready, 'Second ->start is now ready' );
   ok( !$start_f->failure, 'Second ->start did not die' );
}

done_testing;
