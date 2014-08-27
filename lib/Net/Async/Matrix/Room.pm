#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2014 -- leonerd@leonerd.org.uk

package Net::Async::Matrix::Room;

use strict;
use warnings;

# Not really a Notifier but we like the ->maybe_invoke_event style
use base qw( IO::Async::Notifier );

our $VERSION = '0.02';

use Carp;

use Future;

use Struct::Dumb;
use Time::HiRes qw( time );

struct Member => [qw( user_id displayname membership state mtime )];

=head1 NAME

C<Net::Async::Matrix::Room> - a single Matrix room

=head1 DESCRIPTION

An instances in this class are used by L<Net::Async::Matrix> to represent a
single Matrix room.

=cut

=head1 EVENTS

The following events are invoked, either using subclass methods or C<CODE>
references in parameters:

=head2 on_message $member, $content

Invoked on receipt of a new message from the given member.

=head2 on_member $member, %changes

Invoked when a member of the room changes state somehow. The C<$member> object
will already be in the new state. C<%changes> will be a key/value list of
state fields names that were changed, and references to 2-element ARRAYs
containing the old and new values for this field.

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

   foreach (qw( on_message on_member )) {
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

sub initial_sync
{
   my $self = shift;

   $self->{initial_sync} ||= Future->needs_all(
      $self->sync_members,
   );
}

sub sync_messages
{
   my $self = shift;
   my %args = @_;

   my $limit = $args{limit} // 20;

   my $matrix = $self->{matrix};

   $matrix->_do_GET_json( "/rooms/$self->{room_id}/messages/list",
      from  => "END",
      dir   => "b",
      limit => $limit,
   )->then( sub {
      my ( $response ) = @_;

      foreach my $event ( reverse @{ $response->{chunk} } ) {
         # These look like normal events
         next unless my ( $subtype ) = ( $event->{type} =~ m/^m\.room\.(.*)$/ );
         $subtype =~ s/\./_/g;

         if( my $code = $self->can( "_handle_roomevent_$subtype" ) ) {
            $code->( $self, $event );
         }
         else {
            ::log( "TODO: Handle room event $subtype" );
         }
      }

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
         $self->_handle_roomevent_member( $event );
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

   $self->{matrix}->send_room_message( $self->room_id, \%args );
}

sub _get_or_make_member
{
   my $self = shift;
   my ( $user_id ) = @_;

   return $self->{members_by_userid}{$user_id} ||= Member( $user_id, undef, undef, undef, undef );
}

sub _handle_roomevent_config
{
   my $self = shift;
   my ( $event ) = @_;
   my $content = $event->{content};

   # TODO: do we even /get/ this any more?
}

sub _handle_roomevent_message
{
   my $self = shift;
   my ( $event ) = @_;

   my $user_id = $event->{user_id};
   my $member = $self->{members_by_userid}{$user_id}; # caution: might be undef

   # If we don't have a member yet, create a temporary one just to get the
   #   user_id out of
   $member ||= Member( $user_id, undef, undef, undef, undef );

   $self->maybe_invoke_event( on_message =>
      $member, $event->{content} );
}

sub _handle_roomevent_member
{
   my $self = shift;
   my ( $event ) = @_;

   my $user_id = $event->{state_key}; # == user the change applies to
   my $content = $event->{content};

   my $member = $self->_get_or_make_member( $user_id );

   my %changes;
   foreach (qw( membership displayname state )) {
      next unless defined $content->{$_};
      next if defined $member->$_ and $content->{$_} eq $member->$_;

      $changes{$_} = [ $member->$_, $content->{$_} ];
      $member->$_ = $content->{$_};
   }

   defined $content->{mtime_age} and
      $member->mtime = time() - ( $content->{mtime_age} / 1000 );

   $self->maybe_invoke_event( on_member => $member, %changes );

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
      for qw( displayname state );
   $changes{mtime_age} and
      $member->mtime = time() - ( $changes{mtime_age}[1] / 1000 );

   $self->maybe_invoke_event( on_member => $member, %changes );
}

=head1 MEMBERSHIP STRUCTURES

Parameters documented as C<$member> receive a membership struct, which
supports the following methods:

=head2 $user_id = $member->user_id

User ID of the member.

=head2 $displayname = $member->displayname

Profile displayname of the user.

=head2 $membership = $member->membership

Membership state. One of C<invite> or C<join>.

=head2 $state = $member->state

Presence state. One of C<offline>, C<unavailable> or C<online>.

=head2 $mtime = $member->mtime

Epoch time that the presence state last changed.

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
