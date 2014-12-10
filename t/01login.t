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

   make_delay => sub { return Future->new },
);

ok( defined $matrix, '$matrix defined' );

ok( !defined $ua->next_pending, '$ua is idle initially' );

# direct user_id + access_token
{
   my $login_f = $matrix->login(
      user_id => '@my-user-id:localserver.test',
      access_token => "0123456789ABCDEF",
   );

   ok( my $p = $ua->next_pending, '->start sends an HTTP request' );

   my $uri = $p->request->uri;

   is( $uri->authority, "localserver.test",                      '$req->uri->authority' );
   is( $uri->path,      "/_matrix/client/api/v1/initialSync",    '$req->uri->path' );
   is( { $uri->query_form }->{access_token}, "0123456789ABCDEF", '$req->uri->query_form access_token' );

   $p->respond( HTTP::Response->new( 200, "OK", [ "Content-Type" => "application/json" ], '{}' ) );

   ok( $login_f->is_ready, '->login ready with immediate user_id/access_token' );
}

done_testing;
