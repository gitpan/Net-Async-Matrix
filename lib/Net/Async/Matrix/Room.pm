#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2014 -- leonerd@leonerd.org.uk

package Net::Async::Matrix::Room;

use strict;
use warnings;

# Not really a Notifier but we like the ->maybe_invoke_event style
use base qw( IO::Async::Notifier );

our $VERSION = '0.06';

use Carp;

use Future;

use List::Util qw( pairmap );
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
state.

=head2 on_message $member, $content

=head2 on_back_message $member, $content

Invoked on receipt of a new message from the given member, either "live" from
the event stream, or from backward pagination.

=head2 on_membership $member, $event, %changes

=head2 on_back_membership $member, $event, %changes

Invoked on receipt of a membership change event for the given member, either
"live" from the event stream, or from backward pagination. C<%changes> will be
a key/value list of state field names that were changed, whose values are
2-element ARRAY references containing the before/after values of those fields.

 on_membership:      $field_name => [ $old_value, $new_value ]
 on_back_membership: $field_name => [ $new_value, $old_value ]

Note carefully that the second value in each array gives the "updated" value,
in the direction of the change - that is, for C<on_membership> it gives the
new value after the change but for C<on_back_message> it gives the old value
before. Fields whose values did not change are not present in the C<%changes>
list; the values of these can be inspected on the C<$member> object.

It is unspecified what values the C<$member> object has for fields present in
the change list - client code should not rely on these fields.

=head2 on_state_changed $member, $event, %changes

=head2 on_back_state_changed $member, $event, %changes

Invoked on receipt of a change of room state (such as name or topic).

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

   $self->{state} = {};
   $self->{members_by_userid} = {};
}

sub configure
{
   my $self = shift;
   my %params = @_;

   foreach (qw( on_message on_back_message on_membership on_back_membership
         on_presence on_synced_state on_state_changed on_back_state_changed )) {
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
   return $self->{state}{name} || $self->room_id;
}

=head2 $topic = $room->topic

Returns the room topic, if defined

=cut

sub topic
{
   my $self = shift;
   return $self->{state}{topic};
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

sub sync_members
{
   my $self = shift;

   my $matrix = $self->{matrix};

   $matrix->_do_GET_json( "/rooms/$self->{room_id}/members" )->then( sub {
      my ( $response ) = @_;

      foreach my $event ( @{ $response->{chunk} } ) {
         $self->_handle_roomevent_member_initial( $event );
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

=head2 $room->paginate_messages( limit => $n )->get

Requests more messages of back-pagination history.

There is no need to maintain a reference on the returned C<Future>; it will be
adopted by the room object.

=cut

sub paginate_messages
{
   my $self = shift;
   my %args = @_;

   my $limit = $args{limit} // 20;
   my $from  = $self->{pagination_token} // "END";

   my $matrix = $self->{matrix};

   # Since we're now doing pagination, we'll need a second set of member
   # objects
   $self->{back_members_by_userid} //= {
      pairmap { $a => Member( $b->user, $b->displayname, $b->membership ) } %{ $self->{members_by_userid} }
   };

   my $f = $matrix->_do_GET_json( "/rooms/$self->{room_id}/messages",
      from  => $from,
      dir   => "b",
      limit => $limit,
   )->then( sub {
      my ( $response ) = @_;

      foreach my $event ( @{ $response->{chunk} } ) {
         next unless my ( $subtype ) = ( $event->{type} =~ m/^m\.room\.(.*)$/ );
         $subtype =~ s/\./_/g;

         if( my $code = $self->can( "_handle_roomevent_${subtype}_backward" ) ) {
            $code->( $self, $event );
         }
         else {
            $matrix->log( "TODO: Handle room pagination event $subtype" );
         }
      }

      $self->{pagination_token} = $response->{end};
      Future->done( $self );
   });
   $self->adopt_future( $f );
}

sub _handle_roomevent_create_forward
{
   my $self = shift;
   my ( $event ) = @_;

   # Nothing interesting here...
}
*_handle_roomevent_create_initial = \&_handle_roomevent_create_forward;

sub _handle_state_forward
{
   my $self = shift;
   my ( $field, $event ) = @_;

   my $newvalue = $event->{content}{$field};

   my $oldvalue = $self->{state}{$field};
   $self->{state}{$field} = $newvalue;

   $self->maybe_invoke_event( on_state_changed =>
      $self->{members_by_userid}{$event->{user_id}}, $event,
      $field => [ $oldvalue, $newvalue ]
   );
}

sub _handle_state_backward
{
   my $self = shift;
   my ( $field, $event ) = @_;

   my $newvalue = $event->{content}{$field};
   my $oldvalue = $event->{prev_content}{$field};

   $self->maybe_invoke_event( on_back_state_changed =>
      $self->{back_members_by_userid}{$event->{user_id}}, $event,
      $field => [ $newvalue, $oldvalue ]
   );
}

sub _handle_roomevent_name_initial
{
   my $self = shift;
   my ( $event ) = @_;
   $self->{state}{name} = $event->{content}{name};
}

sub _handle_roomevent_name_forward
{
   my $self = shift;
   my ( $event ) = @_;
   $self->_handle_state_forward( name => $event );
}

sub _handle_roomevent_name_backward
{
   my $self = shift;
   my ( $event ) = @_;
   $self->_handle_state_backward( name => $event );
}

sub _handle_roomevent_topic_initial
{
   my $self = shift;
   my ( $event ) = @_;
   $self->{state}{topic} = $event->{content}{topic};
}

sub _handle_roomevent_topic_forward
{
   my $self = shift;
   my ( $event ) = @_;
   $self->_handle_state_forward( topic => $event );
}

sub _handle_roomevent_topic_backward
{
   my $self = shift;
   my ( $event ) = @_;
   $self->_handle_state_backward( topic => $event );
}

sub _handle_roomevent_config_forward
{
   my $self = shift;
   my ( $event ) = @_;
   my $content = $event->{content};

   defined $content->{$_} and $self->{$_} = $content->{$_}
      for qw( visibility room_alias_name );
}
*_handle_roomevent_config_initial = \&_handle_roomevent_config_forward;

sub _handle_roomevent_message_forward
{
   my $self = shift;
   my ( $event ) = @_;

   my $user_id = $event->{user_id};
   my $member = $self->{members_by_userid}{$user_id} or
      warn "TODO: Unknown member '$user_id' for forward message" and return;

   $self->maybe_invoke_event( on_message => $member, $event->{content} );
}

sub _handle_roomevent_message_backward
{
   my $self = shift;
   my ( $event ) = @_;

   my $user_id = $event->{user_id};
   my $member = $self->{back_members_by_userid}{$user_id} or
      warn "TODO: Unknown member '$user_id' for backward message" and return;

   $self->maybe_invoke_event( on_back_message => $member, $event->{content} );
}

sub _handle_roomevent_member_initial
{
   my $self = shift;
   my ( $event ) = @_;

   my $user_id = $event->{state_key}; # == user the change applies to
   my $content = $event->{content};

   warn "ARGH: Room '$self->{room_id}' already has a member '$user_id'\n" and return
      if $self->{members_by_userid}{$user_id};

   my $user = $self->{matrix}->_get_or_make_user( $user_id );

   $self->{members_by_userid}{$user_id} = Member(
      $user, $content->{displayname}, $content->{membership} );
}

sub _handle_roomevent_member_forward
{
   my $self = shift;
   my ( $event ) = @_;

   $self->_handle_roomevent_member( on_membership => $event,
      $self->{members_by_userid}, $event->{prev_content}, $event->{content} );

   my $matrix = $self->{matrix};
   if( $event->{content}{membership} eq "leave" and $event->{state_key} eq $matrix->{user_id} ) {
      $matrix->_on_self_leave( $self );
   }
}

sub _handle_roomevent_member_backward
{
   my $self = shift;
   my ( $event ) = @_;

   $self->_handle_roomevent_member( on_back_membership => $event,
      $self->{back_members_by_userid}, $event->{content}, $event->{prev_content} );
}

sub _handle_roomevent_member
{
   my $self = shift;
   my ( $name, $event, $members, $old, $new ) = @_;

   # Currently, the server "deletes" users from the membership by setting
   # membership to "leave". It's neater if we consider an empty content in
   # that case.
   $_ and $_->{membership} and $_->{membership} eq "leave" and undef $_
      for $old, $new;

   $_ and not keys %$_ and undef $_
      for $old, $new;

   my $user_id = $event->{state_key}; # == user the change applies to

   my $member;
   if( $old ) {
      $member = $members->{$user_id} or
         warn "ARGH: roomevent_member with unknown user id '$user_id'" and return;
   }
   else {
      my $user = $self->{matrix}->_get_or_make_user( $user_id );
      $member = $members->{$user_id} ||=
         Member( $user, undef, undef );
   }

   my %changes;
   foreach (qw( membership displayname )) {
      next if !defined $old->{$_} and !defined $new->{$_};
      next if defined $old->{$_} and defined $new->{$_} and $old->{$_} eq $new->{$_};

      $changes{$_} = [ $old->{$_}, $new->{$_} ];
      $member->$_ = $new->{$_};
   }

   $self->maybe_invoke_event( $name => $event, $member, %changes );

   if( !$new ) {
      delete $members->{$user_id};
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
