#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2014 -- leonerd@leonerd.org.uk

package Net::Async::Matrix::Room;

use strict;
use warnings;

# Not really a Notifier but we like the ->maybe_invoke_event style
use base qw( IO::Async::Notifier );

our $VERSION = '0.05';

use Carp;

use Future;

use Struct::Dumb;
use Time::HiRes qw( time );

struct Member => [qw( user displayname membership )];

=head1 NAME

C<Net::Async::Matrix::Room> - a single Matrix room

=head1 DESCRIPTION

An instances in this class are used by L<Net::Async::Matrix> to represent a
single Matrix room.

=cut

=head1 EVENTS

The following events are invoked, either using subclass methods or C<CODE>
references in parameters:

=head2 on_synced_state

Invoked after the initial sync of the room has been completed as far as the
state, but before message history is replayed.

=head2 on_synced_messages

Invoked after message history sync has been replayed.

=head2 on_message $member, $content

Invoked on receipt of a new message from the given member.

=head2 on_membership $member, %changes

=head2 on_presence $member, %changes

Invoked when a member of the room changes membership or presence state. The
C<$member> object will already be in the new state. C<%changes> will be a
key/value list of state fields names that were changed, and references to
2-element ARRAYs containing the old and new values for this field.

=cut

sub _init
{
   my $self = shift;
   my ( $params ) = @_;
   $self->SUPER::_init( $params );

   $self->{matrix}  = delete $params->{matrix};
   $self->{room_id} = delete $params->{room_id};

   $self->{members_by_userid} = {};
}

sub configure
{
   my $self = shift;
   my %params = @_;

   foreach (qw( on_message on_membership on_presence
         on_synced_state on_synced_messages )) {
      $self->{$_} = delete $params{$_} if exists $params{$_};
   }

   $self->SUPER::configure( %params );
}

=head1 METHODS

=cut

=head2 $id = $room->room_id

Returns the opaque room ID string for the room. Usually this would not be
required, except for long-term persistence uniqueness purposes, or for
inclusion in direct protocol URLs.

=cut

sub room_id
{
   my $self = shift;
   return $self->{room_id};
}

=head2 $name = $room->name

Returns the room name, if defined, otherwise the opaque room ID.

=cut

sub name
{
   my $self = shift;
   return $self->{name} || $self->room_id;
}

sub initial_sync
{
   my $self = shift;

   $self->{initial_sync} ||= Future->needs_all(
      $self->sync_members,
   )->on_done( sub {
      $self->maybe_invoke_event( on_synced_state => );
   });
}

sub sync_messages
{
   my $self = shift;
   my %args = @_;

   my $limit = $args{limit} // 20;

   my $matrix = $self->{matrix};

   $matrix->_do_GET_json( "/rooms/$self->{room_id}/messages",
      from  => "END",
      dir   => "b",
      limit => $limit,
   )->then( sub {
      my ( $response ) = @_;

      foreach my $event ( reverse @{ $response->{chunk} } ) {
         # These look like normal events
         next unless my ( $subtype ) = ( $event->{type} =~ m/^m\.room\.(.*)$/ );
         $subtype =~ s/\./_/g;

         if( my $code = $self->can( "_handle_roomevent_${subtype}_forward" ) ) {
            $code->( $self, $event );
         }
         else {
            $matrix->log( "TODO: Handle room event $subtype" );
         }
      }

      $self->maybe_invoke_event( on_synced_messages => );
      Future->done( $self );
   });
}

sub sync_members
{
   my $self = shift;

   my $matrix = $self->{matrix};

   $matrix->_do_GET_json( "/rooms/$self->{room_id}/members" )->then( sub {
      my ( $response ) = @_;

      foreach my $event ( @{ $response->{chunk} } ) {
         # These look like normal events
         $self->_handle_roomevent_member_forward( $event );
      }

      Future->done( $self );
   });
}

=head2 @members = $room->members

Returns a list of member structs containing the currently known members of the
room, in no particular order.

=cut

sub members
{
   my $self = shift;
   return values %{ $self->{members_by_userid} };
}

=head2 $room->send_message( %args )->get

Sends a new message to the room. Requires a C<type> named argument giving the
message type. Depending on the type, further keys will be required that
specify the message contents:

=over 4

=item text, emote

Require C<body>

=item image, audio, video

Require C<url>

=item location

Require C<geo_uri>

=back

=head2 $room->send_message( $text )->get

A convenient shortcut to sending an C<text> message with a body string and
no additional content.

=cut

my %MSG_REQUIRED_FIELDS = (
   'm.text'  => [qw( body )],
   'm.emote' => [qw( body )],
   'm.image' => [qw( url )],
   'm.audio' => [qw( url )],
   'm.video' => [qw( url )],
   'm.location' => [qw( geo_uri )],
);

sub send_message
{
   my $self = shift;
   my %args = ( @_ == 1 ) ? ( type => "m.text", body => shift ) : @_;

   my $type = $args{msgtype} = delete $args{type} or
      croak "Require a 'type' field";

   $MSG_REQUIRED_FIELDS{$type} or
      croak "Unrecognised message type '$type'";

   foreach (@{ $MSG_REQUIRED_FIELDS{$type} } ) {
      $args{$_} or croak "'$type' messages require a '$_' field";
   }

   $self->{matrix}->_do_POST_json( "/rooms/$self->{room_id}/send/m.room.message", \%args )
      ->then_done()
}

sub _get_or_make_member
{
   my $self = shift;
   my ( $user_id ) = @_;

   my $user = $self->{matrix}->_get_or_make_user( $user_id );

   return $self->{members_by_userid}{$user_id} ||= Member( $user, undef, undef );
}

sub _handle_roomevent_create_forward
{
   my $self = shift;
   my ( $event ) = @_;

   # Nothing interesting here...
}

sub _handle_roomevent_name_forward
{
   my $self = shift;
   my ( $event ) = @_;
   my $content = $event->{content};

   $self->{name} = $content->{name};
}

sub _handle_roomevent_config_forward
{
   my $self = shift;
   my ( $event ) = @_;
   my $content = $event->{content};

   defined $content->{$_} and $self->{$_} = $content->{$_}
      for qw( visibility room_alias_name );
}

sub _handle_roomevent_message_forward
{
   my $self = shift;
   my ( $event ) = @_;

   my $user_id = $event->{user_id};
   my $member = $self->{members_by_userid}{$user_id}; # caution: might be undef

   # If we don't have a member yet, create a temporary one just to get the
   #   user_id out of
   $member ||= Member( $user_id, undef, undef );

   $self->maybe_invoke_event( on_message =>
      $member, $event->{content} );
}

sub _handle_roomevent_member_forward
{
   my $self = shift;
   my ( $event ) = @_;

   my $user_id = $event->{state_key}; # == user the change applies to
   my $content = $event->{content};

   my $member = $self->_get_or_make_member( $user_id );

   my %changes;
   foreach (qw( membership displayname )) {
      next unless defined $content->{$_};
      next if defined $member->$_ and $content->{$_} eq $member->$_;

      $changes{$_} = [ $member->$_, $content->{$_} ];
      $member->$_ = $content->{$_};
   }

   $self->maybe_invoke_event( on_membership => $member, %changes );

   delete $self->{members_by_userid}{$user_id} if $content->{membership} eq "leave";

   my $matrix = $self->{matrix};
   if( $content->{membership} eq "leave" and $user_id eq $matrix->{user_id} ) {
      $matrix->_on_self_leave( $self );
   }
}

sub _handle_event_m_presence
{
   my $self = shift;
   my ( $user, %changes ) = @_;
   my $member = $self->{members_by_userid}{$user->user_id} or return;

   $changes{$_} and $member->$_ = $changes{$_}[1]
      for qw( displayname );

   $self->maybe_invoke_event( on_presence => $member, %changes );
}

=head1 MEMBERSHIP STRUCTURES

Parameters documented as C<$member> receive a membership struct, which
supports the following methods:

=head2 $user = $member->user

User object of the member.

=head2 $displayname = $member->displayname

Profile displayname of the user.

=head2 $membership = $member->membership

Membership state. One of C<invite> or C<join>.

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
