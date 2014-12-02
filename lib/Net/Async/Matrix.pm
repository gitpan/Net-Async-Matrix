#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2014 -- leonerd@leonerd.org.uk

package Net::Async::Matrix;

use strict;
use warnings;

use base qw( IO::Async::Notifier );
IO::Async::Notifier->VERSION( '0.63' ); # adopt_future

our $VERSION = '0.12';
$VERSION = eval $VERSION;

use Carp;

use Future;
use Future::Utils qw( repeat );
use JSON qw( encode_json decode_json );

use Data::Dump 'pp';
use Struct::Dumb;
use Time::HiRes qw( time );

struct User => [qw( user_id displayname presence last_active )];

use Net::Async::Matrix::Room;

use constant PATH_PREFIX => "/_matrix/client/api/v1";
use constant LONGPOLL_SECONDS => 30;

# This is only needed for the (undocumented) recaptcha bypass feature
use constant HAVE_DIGEST_HMAC_SHA1 => eval { require Digest::HMAC_SHA1; };

=head1 NAME

C<Net::Async::Matrix> - use Matrix with L<IO::Async>

=head1 SYNOPSIS

 use Net::Async::Matrix;
 use IO::Async::Loop;

 my $loop = IO::Async::Loop->new;

 my $matrix = Net::Async::Matrix->new(
    server => "my.home.server",
 );

 $loop->add( $matrix );

 $matrix->login(
    user     => '@my-user:home.server',
    password => 'SeKr1t',
 )->get;

=head1 DESCRIPTION

F<Matrix> is an new open standard for interoperable Instant Messaging and VoIP,
providing pragmatic HTTP APIs and open source reference implementations for
creating and running your own real-time communication infrastructure.

This module allows an program to interact with a Matrix homeserver as a
connected user client.

L<http://matrix.org/>

=cut

=head1 EVENTS

The following events are invoked, either using subclass methods or C<CODE>
references in parameters:

=head2 on_log $message

A request to write a debugging log message. This is provided temporarily for
development and debugging purposes, but will at some point be removed when the
code has reached a certain level of stability.

=head2 on_presence $user, %changes

Invoked on receipt of a user presence change event from the homeserver.
C<%changes> will map user state field names to 2-element ARRAY references,
each containing the old and new values of that field.

=head2 on_room_new $room

Invoked when a new room first becomes known about.

Passed an instance of L<Net::Async::Matrix::Room>.

=head2 on_room_del $room

Invoked when the user has now left a room.

=head2 on_invite $event

Invoked on receipt of a room invite. The C<$event> will contain the plain
Matrix event as received; with at least the keys C<inviter> and C<room_id>.

=head2 on_unknown_event $event

Invoked on receipt of any sort of event from the event stream, that is not
recognised by any of the other code. This can be used to handle new kinds of
incoming events.

=cut

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>. In
addition, C<CODE> references for event handlers using the event names listed
above can also be given.

=head2 server => STRING

Hostname and port number to contact the homeserver at. Given in the form

 $hostname:$port

This string will be interpolated directly into HTTP request URLs.

=head2 SSL => BOOL

Whether to use SSL/TLS to communicate with the homeserver. Defaults false.

=head2 SSL_* => ...

Any other parameters whose names begin C<SSL_> will be stored for passing to
the HTTP user agent. See L<IO::Socket::SSL> for more detail.

=head2 path_prefix => STRING

Optional. Gives the path prefix to find the Matrix client API at. Normally
this should not need modification.

=head2 on_room_member, on_room_message => CODE

Optional. Sets default event handlers on new room objects.

=cut

sub _init
{
   my $self = shift;
   my ( $params ) = @_;

   $self->SUPER::_init( $params );

   $params->{ua} ||= do {
      require Net::Async::HTTP;
      Net::Async::HTTP->VERSION( '0.36' ); # SSL params
      my $ua = Net::Async::HTTP->new(
         fail_on_error => 1,
         max_connections_per_host => 3, # allow 2 longpolls + 1 actual command
         user_agent => __PACKAGE__,
      );
      $self->add_child( $ua );
      $ua
   };

   $self->{msgid_next} = 0;

   $self->{users_by_id} = {};
   $self->{rooms_by_id} = {};

   $self->{path_prefix} = PATH_PREFIX;
}

=head1 METHODS

The following methods documented with a trailing call to C<< ->get >> return
L<Future> instances.

=cut

sub configure
{
   my $self = shift;
   my %params = @_;

   foreach (qw( server path_prefix ua SSL
                on_log on_unknown_event on_presence on_room_new on_room_del on_invite
                on_room_member on_room_message )) {
      $self->{$_} = delete $params{$_} if exists $params{$_};
   }

   my $ua = $self->{ua};
   foreach ( grep { m/^SSL_/ } keys %params ) {
      $ua->configure( $_ => delete $params{$_} );
   }

   $self->SUPER::configure( %params );
}

sub log
{
   my $self = shift;
   my ( $message ) = @_;

   $self->{on_log}->( $message ) if $self->{on_log};
}

sub _uri_for_path
{
   my $self = shift;
   my ( $path, %params ) = @_;

   $path = "/$path" unless $path =~ m{^/};

   my $uri = URI->new;
   $uri->scheme( $self->{SSL} ? "https" : "http" );
   $uri->authority( $self->{server} );
   $uri->path( $self->{path_prefix} . $path );

   $params{access_token} = $self->{access_token} if defined $self->{access_token};
   $uri->query_form( %params );

   return $uri;
}

sub _do_GET_json
{
   my $self = shift;
   my ( $path, %params ) = @_;

   $self->{ua}->GET( $self->_uri_for_path( $path, %params ) )->then( sub {
      my ( $response ) = @_;

      $response->content_type eq "application/json" or
         return Future->fail( "Expected application/json response", matrix => );

      Future->done( decode_json( $response->content ), $response );
   });
}

sub _do_send_json
{
   my $self = shift;
   my ( $method, $path, $content ) = @_;

   my $req = HTTP::Request->new( $method, $self->_uri_for_path( $path ) );
   $req->content( encode_json( $content ) );
   $req->header( Content_length => length $req->content ); # ugh

   $req->header( Content_type => "application/json" );

   my $f = $self->{ua}->do_request(
      request => $req,
   )->then( sub {
      my ( $response ) = @_;

      $response->content_type eq "application/json" or
         return Future->fail( "Expected application/json response", matrix => );

      my $content = $response->content;
      if( length $content and $content ne q("") ) {
         eval {
            $content = decode_json( $content );
            1;
         } or
            return Future->fail( "Unable to parse JSON response $content" );
         return Future->done( $content, $response );
      }
      else {
         # server yields empty strings sometimes... :/
         return Future->done( undef, $response );
      }
   });

   return $self->adopt_future( $f );
}

sub _do_PUT_json  { shift->_do_send_json( PUT  => @_ ) }
sub _do_POST_json { shift->_do_send_json( POST => @_ ) }

sub _do_DELETE
{
   my $self = shift;
   my ( $path, %params ) = @_;

   $self->{ua}->do_request(
      method => "DELETE",
      uri    => $self->_uri_for_path( $path, %params ),
   );
}

=head2 $matrix->login( %params )->get

Performs the necessary steps required to authenticate with the configured
Home Server, actually obtain an access token and starting the event stream.
The returned C<Future> will eventually yield the C<$matrix> object itself, so
it can be easily chained.

There are various methods of logging in supported by Matrix; the following
sets of arguments determine which is used:

=over 4

=item user_id, password

Log in via the C<m.login.password> method.

=item user_id, access_token

Directly sets the C<user_id> and C<access_token> fields, bypassing the usual
login semantics. This presumes you already have an existing access token to
re-use, obtained by some other mechanism. This exists largely for testing
purposes.

=back

=cut

sub login
{
   my $self = shift;
   my %params = @_;

   if( defined $params{user_id} and defined $params{access_token} ) {
      $self->{$_} = $params{$_} for qw( user_id access_token );
      $self->start;
      return Future->done( $self );
   }

   # Otherwise; try to obtain the login flow information
   $self->_do_GET_json( "/login" )->then( sub {
      my ( $response ) = @_;
      my $flows = $response->{flows};

      my @supported;
      foreach my $flow ( @$flows ) {
         next unless my ( $type ) = $flow->{type} =~ m/^m\.login\.(.*)$/;
         push @supported, $type;

         next unless my $code = $self->can( "_login_with_$type" );
         next unless my $f = $code->( $self, %params );

         return $f;
      }

      Future->fail( "Unsure how to log in (server supports @supported)", matrix => );
   });
}

sub _login_with_password
{
   my $self = shift;
   my %params = @_;

   return unless defined $params{user_id} and defined $params{password};

   $self->_do_POST_json( "/login",
      { type => "m.login.password", user => $params{user_id}, password => $params{password} }
   )->then( sub {
      my ( $resp ) = @_;
      return $self->login( %$resp ) if defined $resp->{access_token};
      return Future->fail( "Expected server to respond with 'access_token'", matrix => );
   });
}

=head2 $matrix->register( %params )->get

Performs the necessary steps required to create a new account on the
configured Home Server.

=cut

sub register
{
   my $self = shift;
   my %params = @_;

   $self->_do_GET_json( "/register" )->then( sub {
      my ( $response ) = @_;
      my $flows = $response->{flows};

      my @supported;
      # Try to find a flow for which we can support all the stages
      FLOW: foreach my $flow ( @$flows ) {
         # Might or might not find a 'stages' key
         my @stages = $flow->{stages} ? @{ $flow->{stages} } : ( $flow->{type} );

         push @supported, join ",", @stages;

         my @flowcode;
         foreach my $stage ( @stages ) {
            next FLOW unless my ( $type ) = $stage =~ m/^m\.login\.(.*)$/;
            $type =~ s/\./_/g;

            next FLOW unless my $method = $self->can( "_register_with_$type" );
            next FLOW unless my $code = $method->( $self, %params );

            push @flowcode, $code;
         }

         # If we've got this far then we know we can implement all the stages
         my $start = Future->new;
         my $tail = $start;
         $tail = $tail->then( $_ ) for @flowcode;

         $start->done();
         return $tail->then( sub {
            my ( $resp ) = @_;
            return $self->login( %$resp ) if defined $resp->{access_token};
            return Future->fail( "Expected server to respond with 'access_token'", matrix => );
         });
      }

      Future->fail( "Unsure how to register (server supports @supported)", matrix => );
   });
}

sub _register_with_password
{
   my $self = shift;
   my %params = @_;

   return unless defined( my $password = $params{password} );

   return sub {
      my ( $resp ) = @_;

      $self->_do_POST_json( "/register", {
         type    => "m.login.password",
         session => $resp->{session},

         user     => $params{user_id},
         password => $password,
      } );
   }
}

sub _register_with_recaptcha
{
   my $self = shift;
   my %params = @_;

   return unless defined( my $secret = $params{captcha_bypass_secret} ) and
      defined $params{user_id};

   warn "Cannot use captcha_bypass_secret to bypass m.register.recaptcha without Digest::HMAC_SHA1\n" and return
      if !HAVE_DIGEST_HMAC_SHA1;

   my $digest = Digest::HMAC_SHA1::hmac_sha1_hex( $params{user_id}, $secret );

   return sub {
      my ( $resp ) = @_;

      $self->_do_POST_json( "/register", {
         type    => "m.login.recaptcha",
         session => $resp->{session},

         user                => $params{user_id},
         captcha_bypass_hmac => $digest,
      } );
   };
}

=head2 $f = $matrix->start

Performs the initial IMSync on the server, and starts the event stream to
begin receiving events.

While this method does return a C<Future> it is not required that the caller
keep track of this; the object itself will store it. It will complete when the
initial IMSync has fininshed, and the event stream has started.

If the initial sync has already been requested, this method simply returns the
future it returned the last time, ensuring that you can await the client
starting up simply by calling it; it will not start a second time.

=cut

sub start
{
   my $self = shift;

   defined $self->{access_token} or croak "Cannot ->start without an access token";

   return $self->{start_f} ||= do {
      my $f = $self->_do_GET_json( "/initialSync", limit => 0 )
      ->then( sub {
         my ( $sync ) = @_;

         foreach ( @{ $sync->{rooms} } ) {
            my $room_id = $_->{room_id};
            my $membership = $_->{membership};

            if( $membership eq "join" ) {
               my $state = $_->{state};

               my $room = $self->_get_or_make_room( $room_id );
               $room->_handle_event_initial( $_ ) for @$state;

               $room->maybe_invoke_event( on_synced_state => );
            }
            elsif( $membership eq "invite" ) {
               $self->maybe_invoke_event( on_invite => $_ );
            }
            else {
               $self->log( "TODO: imsync returned a room in membership state $membership" );
            }
         }

         # Now push use presence messages
         foreach ( @{ $sync->{presence} } ) {
            $self->_incoming_event( $_ );
         }

         $self->start_longpoll( start => $sync->{end} );
         Future->done;
      });
      $self->adopt_future( $f );
   };
}

=head2 $matrix->stop

Stops the event stream. After calling this you will need to use C<start> again
to continue receiving events.

=cut

sub stop
{
   my $self = shift;

   ( delete $self->{start_f} )->cancel;
   $self->stop_longpoll;
}

## Longpoll events

sub start_longpoll
{
   my $self = shift;
   my %args = @_;

   $self->stop_longpoll;
   $self->{longpoll_last_token} = $args{start} // "END";

   $self->{longpoll_f} = repeat {
      my $last_token = $self->{longpoll_last_token};

      my $uri = $self->_uri_for_path( "/events",
         $last_token ? ( from => $last_token ) : (),
         timeout => LONGPOLL_SECONDS * 1000, # msec
      );

      Future->wait_any(
         $self->loop->timeout_future( after => LONGPOLL_SECONDS + 5 ),

         $self->{ua}->GET( $uri )->then( sub {
            my ( $response ) = @_;
            my $data = decode_json( $response->content );
            $self->_incoming_event( $_ ) foreach @{ $data->{chunk} };
            $self->{longpoll_last_token} = $data->{end};

            Future->done();
         }),
      )->else( sub {
         my ( $failure ) = @_;
         warn "Longpoll failed - $failure\n";

         $self->loop->delay_future( after => 3 )
      });
   } while => sub { 1 };
}

sub stop_longpoll
{
   my $self = shift;

   ( delete $self->{longpoll_f} )->cancel if $self->{longpoll_f};
}

sub _get_or_make_user
{
   my $self = shift;
   my ( $user_id ) = @_;

   return $self->{users_by_id}{$user_id} ||= User( $user_id, undef, undef, undef );
}

sub _make_room
{
   my $self = shift;
   my ( $room_id ) = @_;

   $self->{rooms_by_id}{$room_id} and
      croak "Already have a room with ID '$room_id'";

   my @args;
   foreach (qw( message member )) {
      push @args, "on_$_" => $self->{"on_room_$_"} if $self->{"on_room_$_"};
   }

   my $room = $self->{rooms_by_id}{$room_id} = $self->make_room(
      matrix  => $self,
      room_id => $room_id,
      @args,
   );
   $self->add_child( $room );

   $self->maybe_invoke_event( on_room_new => $room );

   return $room;
}

sub make_room
{
   my $self = shift;
   return Net::Async::Matrix::Room->new( @_ );
}

sub _get_or_make_room
{
   my $self = shift;
   my ( $room_id ) = @_;

   return $self->{rooms_by_id}{$room_id} //
      $self->_make_room( $room_id );
}

=head2 $user = $matrix->myself

Returns the user object representing the connected user.

=cut

sub myself
{
   my $self = shift;
   return $self->_get_or_make_user( $self->{user_id} );
}

=head2 $user = $matrix->user( $user_id )

Returns the user object representing a user of the given ID, if defined, or
C<undef>.

=cut

sub user
{
   my $self = shift;
   my ( $user_id ) = @_;
   return $self->{users_by_id}{$user_id};
}

sub _incoming_event
{
   my $self = shift;
   my ( $event ) = @_;

   my @type_parts = split m/\./, $event->{type};
   my @subtype_args;

   while( @type_parts ) {
      if( my $handler = $self->can( "_handle_event_" . join "_", @type_parts ) ) {
         $handler->( $self, @subtype_args, $event );
         return;
      }

      unshift @subtype_args, pop @type_parts;
   }

   $self->maybe_invoke_event(
      on_unknown_event => $event
   ) or $self->log( "  incoming event=".pp($event) );
}

sub _on_self_leave
{
   my $self = shift;
   my ( $room ) = @_;

   $self->maybe_invoke_event( on_room_del => $room );

   delete $self->{rooms_by_id}{$room->room_id};
}

=head2 $name = $matrix->get_displayname->get

=head2 $matrix->set_displayname( $name )->get

Accessor and mutator for the user account's "display name" profile field.

=cut

sub get_displayname
{
   my $self = shift;
   my ( $user_id ) = @_;

   $user_id //= $self->{user_id};

   $self->_do_GET_json( "/profile/$user_id/displayname" )->then( sub {
      my ( $content ) = @_;

      Future->done( $content->{displayname} );
   });
}

sub set_displayname
{
   my $self = shift;
   my ( $name ) = @_;

   $self->_do_PUT_json( "/profile/$self->{user_id}/displayname",
      { displayname => $name }
   );
}

=head2 ( $presence, $msg ) = $matrix->get_presence->get

=head2 $matrix->set_presence( $presence, $msg )->get

Accessor and mutator for the user's current presence state and optional status
message string.

=cut

sub get_presence
{
   my $self = shift;

   $self->_do_GET_json( "/presence/$self->{user_id}/status" )->then( sub {
      my ( $status ) = @_;
      Future->done( $status->{presence}, $status->{status_msg} );
   });
}

sub set_presence
{
   my $self = shift;
   my ( $presence, $msg ) = @_;

   my $status = {
      presence => $presence,
   };
   $status->{status_msg} = $msg if defined $msg;

   $self->_do_PUT_json( "/presence/$self->{user_id}/status", $status )
}

sub get_presence_list
{
   my $self = shift;

   $self->_do_GET_json( "/presence_list/$self->{user_id}" )->then( sub {
      my ( $events ) = @_;

      my @users;
      foreach my $event ( @$events ) {
         my $user = $self->_get_or_make_user( $event->{user_id} );
         foreach (qw( presence displayname )) {
            $user->$_ = $event->{$_} if defined $event->{$_};
         }

         push @users, $user;
      }

      Future->done( @users );
   });
}

sub invite_presence
{
   my $self = shift;
   my ( $remote ) = @_;

   $self->_do_POST_json( "/presence_list/$self->{user_id}",
      { invite => [ $remote ] }
   );
}

sub drop_presence
{
   my $self = shift;
   my ( $remote ) = @_;

   $self->_do_POST_json( "/presence_list/$self->{user_id}",
      { drop => [ $remote ] }
   );
}

=head2 ( $room, $room_alias ) = $matrix->create_room( $alias_localpart )->get

Requests the creation of a new room and associates a new alias with the given
localpart on the server. The returned C<Future> will return an instance of
L<Net::Async::Matrix::Room> and a string containing the full alias that was
created.

=cut

sub create_room
{
   my $self = shift;
   my ( $room_alias ) = @_;

   my $body = {};
   $body->{room_alias_name} = $room_alias if defined $room_alias;
   # TODO: visibility?

   $self->_do_POST_json( "/createRoom", $body )->then( sub {
      my ( $content ) = @_;

      my $room = $self->_get_or_make_room( $content->{room_id} );
      $room->initial_sync
         ->then_done( $room, $content->{room_alias} );
   });
}

=head2 $room = $matrix->join_room( $room_alias_or_id )->get

Requests to join an existing room with the given alias name or plain room ID.
If this room is already known by the C<$matrix> object, this method simply
returns it.

=cut

sub join_room
{
   my $self = shift;
   my ( $room_alias ) = @_;

   my $f;
   if( $room_alias =~ m/^#/ ) {
      $f = $self->_do_POST_json( "/join/$room_alias", {} )->then( sub {
         my ( $content ) = @_;
         Future->done( $content->{room_id} );
      });
   }
   elsif( $room_alias =~ m/^!/ ) {
      # Internal room ID directly
      $f = $self->_do_PUT_json( "/rooms/$room_alias/state/m.room.member/$self->{user_id}", {
         membership => "join",
      } )->then_done( $room_alias );
   }

   $f->then( sub {
      my ( $room_id ) = @_;
      if( my $room = $self->{rooms_by_id}{$room_id} ) {
         return Future->done( $room );
      }
      else {
         my $room = $self->_make_room( $room_id );
         $room->initial_sync
            ->then_done( $room );
      }
   });
}

sub room_list
{
   my $self = shift;

   $self->_do_GET_json( "/users/$self->{user_id}/rooms/list" )
      ->then( sub {
         my ( $response ) = @_;
         Future->done( pp($response) );
      });
}

=head2 $matrix->add_alias( $alias, $room_id )->get

=head2 $matrix->delete_alias( $alias )->get

Performs a directory server request to create the given room alias name, to
point at the room ID, or to remove it again.

Note that this is likely only to be supported for alias names scoped within
the homeserver the client is connected to, and that additionally some form of
permissions system may be in effect on the server to limit access to the
directory server.

=cut

sub add_alias
{
   my $self = shift;
   my ( $alias, $room_id ) = @_;

   $self->_do_PUT_json( "/directory/room/$alias",
      { room_id => $room_id },
   )->then_done();
}

sub delete_alias
{
   my $self = shift;
   my ( $alias ) = @_;

   $self->_do_DELETE( "/directory/room/$alias" )
      ->then_done();
}

## Incoming events

sub _handle_event_m_presence
{
   my $self = shift;
   my ( $event ) = @_;
   my $content = $event->{content};

   my $user = $self->_get_or_make_user( $content->{user_id} );

   my %changes;
   foreach (qw( presence displayname )) {
      next unless defined $content->{$_};
      next if defined $user->$_ and $content->{$_} eq $user->$_;

      $changes{$_} = [ $user->$_, $content->{$_} ];
      $user->$_ = $content->{$_};
   }

   if( defined $content->{last_active_ago} ) {
      my $new_last_active = time() - ( $content->{last_active_ago} / 1000 );

      $changes{last_active} = [ $user->last_active, $new_last_active ];
      $user->last_active = $new_last_active;
   }

   $self->maybe_invoke_event(
      on_presence => $user, %changes
   );

   foreach my $room ( values %{ $self->{rooms_by_id} } ) {
      $room->_handle_event_m_presence( $user, %changes );
   }
}

sub _handle_event_m_room
{
   my $self = shift;
   my $event = pop;
   my @type_parts = @_;

   # Room messages for existing rooms
   my $handler;
   if( $handler = $self->{rooms_by_id}{$event->{room_id}} ) {
      # OK
   }
   elsif( $event->{state_key} eq $self->{user_id} ) {
      $handler = $self;
   }
   else {
      $self->log( "TODO: Room event on unknown room ID $event->{room_id} not about myself" );
      # Ignore it for now
      return;
   }

   my @subtype_parts;
   while( @type_parts ) {
      if( my $code = $handler->can( "_handle_roomevent_" . join "_", @type_parts, "forward" ) ) {
         $code->( $handler, @subtype_parts, $event );
         return;
      }

      unshift @subtype_parts, pop @type_parts;
   }

   $self->log( "Unhandled room event " . join( "_", @subtype_parts ) . "\n" .
      pp( $event ) );
}

sub _handle_roomevent_member_forward
{
   my $self = shift;
   my $event = pop;

   my $content = $event->{content};
   my $membership = $content->{membership};

   if( $membership eq "join" ) {
      my $room = $self->_get_or_make_room( $event->{room_id} );
      $self->adopt_future(
         # TODO: "members" isn't enough. We want other config too...
         $room->initial_sync
      );
   }
   elsif( $membership eq "invite" ) {
      $self->maybe_invoke_event( on_invite => $event );
   }
   else {
      $self->log( "Unhandled selfroom event member membership=$membership" );
   }
}

=head1 USER STRUCTURES

Parameters documented as C<$user> receive a user struct, which supports the
following methods:

=head2 $user_id = $user->user_id

User ID of the user.

=head2 $displayname = $user->displayname

Profile displayname of the user.

=head2 $presence = $user->presence

Presence state. One of C<offline>, C<unavailable> or C<online>.

=head2 $last_active = $user->last_active

Epoch time that the user was last active.

=cut

=head1 SUBCLASSING METHODS

The following methods are not normally required by users of this class, but
are provided for the convenience of subclasses to override.

=head2 $room = $matrix->make_room( %params )

Returns a new instance of L<Net::Async::Matrix::Room>.

=cut

=head1 SEE ALSO

=over 4

=item *

L<http://matrix.org/> - matrix.org home page

=item *

L<https://github.com/matrix-org> - matrix.org on github

=back

=cut

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
