#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2014 -- leonerd@leonerd.org.uk

package Net::Async::Matrix;

use strict;
use warnings;

use base qw( IO::Async::Notifier );
IO::Async::Notifier->VERSION( '0.63' ); # adopt_future

our $VERSION = '0.02';

use Carp;

use Future;
use Future::Utils qw( repeat );
use JSON qw( encode_json decode_json );

use Data::Dump 'pp';
use POSIX qw( strftime );
use Struct::Dumb;
use Time::HiRes qw( time );

struct User => [qw( user_id displayname state presence_mtime )];

use Net::Async::Matrix::Room;

use constant PATH_PREFIX => "/matrix/client/api/v1";
use constant LONGPOLL_SECONDS => 30;

=head1 NAME

C<Net::Async::Matrix> - use Matrix with L<IO::Async>

=head1 SYNOPSIS

 TODO

=head1 DESCRIPTION

This module allows an program to interact with a Matrix homeserver as a
connected user client.

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

=head2 on_room_add $room

Invoked when a new room has completed its initial sync, either because of the
client's initial sync, or because it was just created or joined. Note that if
default C<on_room_*> event handlers are defined, these may have already been
invoked before C<on_room_add>.

Passed an instance of L<Net::Async::Matrix::Room>.

=head2 on_room_del $room

Invoked when the user has now left a room.

=cut

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>. In
addition, C<CODE> references for event handlers using the event names listed
above can also be given.

=head2 user_id => STRING

=head2 access_token => STRING

Optional login details to use for logging in as an existing user if an access
token is already known. For registering a new user, see instead the
C<register> method.

=head2 server => STRING

Hostname and port number to contact the homeserver at. Given in the form

 $hostname:$port

This string will be interpolated directly into HTTP request URLs.

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
      my $ua = Net::Async::HTTP->new(
         fail_on_error => 1,
         max_connections_per_host => 3, # allow 2 longpolls + 1 actual command
         user_agent => __PACKAGE__,
      );
      $self->add_child( $ua );
      $ua
   };

   $self->{msgid_prefix} = strftime( '%Y%m%dT%H%M%S', localtime );
   $self->{msgid_next} = 0;

   $self->{users_by_id} = {};
   $self->{rooms_by_id} = {};
}

=head1 METHODS

The following methods documented with a trailing call to C<< ->get >> return
L<Future> instances.

=cut

sub configure
{
   my $self = shift;
   my %params = @_;

   foreach (qw( user_id access_token server ua
                on_log on_presence on_room_add on_room_del
                on_room_member on_room_message )) {
      $self->{$_} = delete $params{$_} if exists $params{$_};
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
   $uri->scheme( "http" );
   $uri->authority( $self->{server} );
   $uri->path( PATH_PREFIX . $path );

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
   my ( $path ) = @_;

   $self->{ua}->do_request(
      method => "DELETE",
      uri    => $self->_uri_for_path( $path )
   )->then( sub {
      my ( $response ) = @_;

      Future->done;
   });
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

   return $self->{start_f} ||= do {
      my $event_token;

      my $f = $self->get_current_event_token->then( sub {
         ( $event_token ) = @_;

         $self->initial_sync
      })->then( sub {
         my ( $sync ) = @_;

         my @roomsync_f;

         foreach ( @{ $sync->{rooms} } ) {
            my $room_id = $_->{room_id};
            my $membership = $_->{membership};

            if( $membership eq "join" ) {
               my $state = $_->{state};

               my $room = $self->_make_room( $room_id );
               $self->_incoming_event( $_ ) for @$state;

               $self->maybe_invoke_event( on_room_add => $room );

               push @roomsync_f, $room->sync_messages( limit => 50 );
            }
            elsif( $membership eq "invite" ) {
               $self->log( "TODO: imsync returned a room invite" );
            }
            # Else: TODO something else?
         }

         Future->needs_all( @roomsync_f );
      })->then( sub {
         $self->start_longpoll( start => $event_token );
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

sub get_current_event_token
{
   my $self = shift;

   $self->_do_GET_json( "/events", from => "END", timeout => 0 )->then( sub {
      my ( $response ) = @_;
      Future->done( $response->{end} );
   });
}

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

      $self->{ua}->GET( $uri,
         on_header => sub {
            my ( $header ) = @_;

            my $json = JSON->new;
            return sub {
               my ( $data ) = @_ or return $header;

               $header->add_content( $data );

               foreach my $chunk ( $json->incr_parse( $data ) ) {
                  $self->_incoming_event( $_ ) foreach @{ $chunk->{chunk} };

                  $self->{longpoll_last_token} = $chunk->{end};
               }
            }
         },
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
   my ( $room_id, @args ) = @_;

   $self->{rooms_by_id}{$room_id} and
      croak "Already have a room with ID '$room_id'";

   foreach (qw( message member )) {
      push @args, "on_$_" => $self->{"on_room_$_"} if $self->{"on_room_$_"};
   }

   my $room = $self->{rooms_by_id}{$room_id} = Net::Async::Matrix::Room->new(
      matrix  => $self,
      room_id => $room_id,
      @args,
   );
   $self->add_child( $room );

   return $room;
}

sub _get_or_make_room
{
   my $self = shift;
   my ( $room_id, @args ) = @_;

   return $self->{rooms_by_id}{$room_id} //
      $self->_make_room( $room_id, @args );
}

=head2 $user = $matrix->myself

Returns the user object representing the connected user.

=cut

sub myself
{
   my $self = shift;
   return $self->_get_or_make_user( $self->{user_id} );
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

   $self->log( "  incoming event=".pp($event) );
}

sub _on_self_leave
{
   my $self = shift;
   my ( $room ) = @_;

   $self->maybe_invoke_event( on_room_del => $room );

   delete $self->{rooms_by_id}{$room->room_id};
}

=head2 ( $user_id, $access_token ) = $matrix->register( $localpart )->get

Sends a user account registration request to the Matrix homeserver to create a
new account. On successful completion, the returned user ID and token are
stored by the object itself and the event stream is started.

=cut

sub register
{
   my $self = shift;
   my ( $localpart ) = @_;

   # TODO: Matrix calls this a "user_id" but it's the localpart that you want.
   # SHOULD FIX
   $self->_do_POST_json( "/register", { user_id => $localpart } )->then( sub {
      my ( $content ) = @_;

      $self->{user_id} = $content->{user_id};
      $self->{access_token} = $content->{access_token};

      $self->start;

      Future->done( $content->{user_id}, $content->{access_token} );
   });
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

=head2 ( $state, $msg ) = $matrix->get_presence->get

=head2 $matrix->set_presence( $state, $msg )->get

Accessor and mutator for the user's current presence state and optional status
message string.

=cut

sub get_presence
{
   my $self = shift;

   $self->_do_GET_json( "/presence/$self->{user_id}/status" )->then( sub {
      my ( $status ) = @_;
      Future->done( $status->{state}, $status->{status_msg} );
   });
}

sub set_presence
{
   my $self = shift;
   my ( $state, $msg ) = @_;

   my $status = {
      state => $state,
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
         foreach (qw( state displayname )) {
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
      $self->maybe_invoke_event( on_room_add => $room );
      Future->done( $room, $content->{room_alias} );
   });
}

=head2 $matrix->join_room( $room_alias_or_id )->get

Requests to join an existing room with the given alias name or plain room ID.

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
      my $room = $self->_get_or_make_room( $room_id );
      $room->initial_sync
   });
}

sub leave_room
{
   my $self = shift;
   my ( $roomid ) = @_;

   $self->_do_DELETE( "/rooms/$roomid/state/m.room.member/$self->{user_id}" );
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

sub send_room_message
{
   my $self = shift;
   my ( $roomid, $content ) = @_;

   my $msgid = "$self->{msgid_prefix}-$self->{msgid_next}";
   $self->{msgid_next}++;

   $self->_do_PUT_json( "/rooms/$roomid/messages/$self->{user_id}/$msgid", $content );
}

=head2 $syncdata = $matrix->initial_sync->get( %args )

Performs an IMSync operation, fetching the set of rooms the user is a member
of, their current state, and an optional snapshot of the latest messages
there.

Takes the following named arguments:

=over 4

=item limit => INT

Optional number of messages per room to return. Defaults to zero; fetching
only the list of rooms and their state, without any message snapshots.

=back

=cut

sub initial_sync
{
   my $self = shift;
   my %args = @_;

   $args{limit} //= 0;

   $self->_do_GET_json( "/initialSync",
      limit => $args{limit},
   );
}

## Incoming events

sub _handle_event_m_presence
{
   my $self = shift;
   my ( $event ) = @_;
   my $content = $event->{content};

   my $user = $self->_get_or_make_user( $content->{user_id} );

   my %changes;
   foreach (qw( displayname state )) {
      next unless defined $content->{$_};
      next if defined $user->$_ and $content->{$_} eq $user->$_;

      $changes{$_} = [ $user->$_, $content->{$_} ];
      $user->$_ = $content->{$_};
   }

   if( defined $content->{mtime_age} ) {
      $changes{mtime_age} = [ undef, $content->{mtime_age} ];
      $user->presence_mtime = time() - ( $content->{mtime_age} / 1000 );
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
      if( my $code = $handler->can( "_handle_roomevent_" . join "_", @type_parts ) ) {
         $code->( $handler, @subtype_parts, $event );
         return;
      }

      unshift @subtype_parts, pop @type_parts;
   }

   $self->log( "Unhandled room event " . join "_", @subtype_parts );
}

sub _handle_roomevent_member
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
            ->on_done( sub {
               $self->maybe_invoke_event( on_room_add => $room )
            })
      );
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

=head2 $state = $user->state

Presence state. One of C<offline>, C<unavailable> or C<online>.

=head2 $presence_mtime = $user->presence_mtime

Epoch time that the presence state last changed.

=cut

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
