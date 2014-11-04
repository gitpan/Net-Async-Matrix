#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2014 -- leonerd@leonerd.org.uk

package Net::Async::Matrix::Room;

use strict;
use warnings;

# Not really a Notifier but we like the ->maybe_invoke_event style
use base qw( IO::Async::Notifier );

our $VERSION = '0.10';

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

=head2 on_message $member, $content, $event

=head2 on_back_message $member, $content, $event

Invoked on receipt of a new message from the given member, either "live" from
the event stream, or from backward pagination.

=head2 on_membership $member, $event, $subject_member, %changes

=head2 on_back_membership $member, $event, $subject_member, %changes

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

In most cases when users change their own membership status (such as normal
join or leave), the C<$member> and C<$subject_member> parameters refer to the
same object. In other cases, such as invites or kicks, the C<$member>
parameter refers to the member performing the change, and the
C<$subject_member> refers to member that the change is about.

=head2 on_state_changed $member, $event, %changes

=head2 on_back_state_changed $member, $event, %changes

Invoked on receipt of a change of room state (such as name or topic).

In the special case of room aliases, because they are considered "state" but
are stored per-homeserver, the changes value will consist of three fields; the
old and new values I<from that home server>, and a list of the known aliases
from all the other servers:

 on_state_changed:      aliases => [ $old, $new, $other ]
 on_back_state_changed: aliases => [ $new, $old, $other ]

This allows a client to detect deletions and additions by comparing the before
and after lists, while still having access to the full set of before or after
aliases, should it require it.

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
   # Power levels can exist for users who aren't in the room. So store them
   # separately, rather than on the member objects themselves
   $self->{level_by_userid} = {};

   $self->{aliases_by_hs} = {};
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

sub _do_GET_json
{
   my $self = shift;
   my ( $path, @args ) = @_;

   $self->{matrix}->_do_GET_json( "/rooms/$self->{room_id}" . $path, @args );
}

sub _do_PUT_json
{
   my $self = shift;
   my ( $path, $content ) = @_;

   $self->{matrix}->_do_PUT_json( "/rooms/$self->{room_id}" . $path, $content );
}

sub _do_POST_json
{
   my $self = shift;
   my ( $path, $content ) = @_;

   $self->{matrix}->_do_POST_json( "/rooms/$self->{room_id}" . $path, $content );
}

sub initial_sync
{
   my $self = shift;

   # There is not actually an 'initialSync' API for individual rooms, yet. See
   #   https://matrix.org/jira/browse/SYN-55

   $self->{initial_sync} ||= $self->_do_GET_json( "/state" )->then( sub {
      my ( $events ) = @_;

      $self->_handle_event_initial( $_ ) for @$events;

      $self->maybe_invoke_event( on_synced_state => );
      Future->done;
   });
}

sub _handle_event_initial
{
   my $self = shift;
   my ( $event ) = @_;

   $event->{type} =~ m/^m\.room\.(.*)$/ or return;
   my $method = "_handle_roomevent_" . join( "_", split m/\./, $1 ) . "_initial";

   if( my $code = $self->can( $method ) ) {
      $code->( $self, $event );
   }
   else {
      warn "TODO: initial room event $event->{type}\n";
   }
}

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

sub name
{
   my $self = shift;
   return $self->{state}{name} || $self->room_id;
}

=head2 $room->set_name( $name )->get

Requests to set a new room name.

=cut

sub set_name
{
   my $self = shift;
   my ( $name ) = @_;

   $self->_do_PUT_json( "/state/m.room.name", { name => $name } )
      ->then_done();
}

=head2 @aliases = $room->aliases

Returns a list of all the known room alias names taken from the
C<m.room.alias> events. Note that these are simply names I<claimed> to have
aliases from the alias events; a client ought to still check that these are
valid before presenting them to the user as such, or in other ways relying on
their values.

=cut

sub _handle_roomevent_aliases_initial
{
   my $self = shift;
   my ( $event ) = @_;

   my $homeserver = $event->{state_key};

   $self->{aliases_by_hs}{$homeserver} = [ @{ $event->{content}{aliases} } ];
}

sub _handle_roomevent_aliases_forward
{
   my $self = shift;
   my ( $event ) = @_;

   my $homeserver = $event->{state_key};

   my $new = $event->{content}{aliases} // [];
   my $old = $event->{prev_content}{aliases} // [];

   $self->{aliases_by_hs}{$homeserver} = [ @$new ];

   my @others = map { @{ $self->{aliases_by_hs}{$_} } }
                grep { $_ ne $homeserver }
                keys %{ $self->{aliases_by_hs} };

   $self->maybe_invoke_event( on_state_changed =>
      $self->{members_by_userid}{$event->{user_id}}, $event,
      aliases => [ $old, $new, \@others ]
   );
}

sub _handle_roomevent_aliases_backward
{
   my $self = shift;
   my ( $event ) = @_;

   my $homeserver = $event->{state_key};

   my $new = $event->{prev_content}{aliases} // [];
   my $old = $event->{content}{aliases} // [];

   $self->{back_aliases_by_hs}{$homeserver} = [ @$new ];

   my @others = map { @{ $self->{back_aliases_by_hs}{$_} } }
                grep { $_ ne $homeserver }
                keys %{ $self->{back_aliases_by_hs} };

   $self->maybe_invoke_event( on_back_state_changed =>
      $self->{back_members_by_userid}{$event->{user_id}}, $event,
      aliases => [ $old, $new, \@others ]
   );
}

sub aliases
{
   my $self = shift;

   return map { @$_ } values %{ $self->{aliases_by_hs} };
}

=head2 $rule = $room->join_rule

Returns the current C<join_rule> for the room; a string giving the type of
access new members may get:

=over 4

=item * public

Any user may join without further permission

=item * invite

Users may only join if explicitly invited

=item * knock

Any user may send a knock message to request access; may only join if invited

=item * private

No new users may join the room

=back

=cut

sub _handle_roomevent_join_rules_initial
{
   my $self = shift;
   my ( $event ) = @_;
   $self->{state}{join_rule} = $event->{content}{join_rule};
}

sub _handle_roomevent_join_rules_forward
{
   my $self = shift;
   my ( $event ) = @_;
   $self->_handle_state_forward( join_rule => $event );
}

sub _handle_roomevent_join_rules_backward
{
   my $self = shift;
   my ( $event ) = @_;
   $self->_handle_state_backward( join_rule => $event );
}

sub join_rule
{
   my $self = shift;
   return $self->{state}{join_rule};
}

=head2 $topic = $room->topic

Returns the room topic, if defined

=cut

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

sub topic
{
   my $self = shift;
   return $self->{state}{topic};
}

=head2 $room->set_topic( $topic )->get

Requests to set a new room topic.

=cut

sub set_topic
{
   my $self = shift;
   my ( $topic ) = @_;

   $self->_do_PUT_json( "/state/m.room.topic", { topic => $topic } )
      ->then_done();
}

=head2 %levels = $room->levels

Returns a key/value list of the room levels; that is, the member power level
required to perform each of the named actions.

=cut

sub _handle_generic_level
{
   my $self = shift;
   my ( $phase, $level, $convert, $event ) = @_;

   foreach my $k (qw( content prev_content )) {
      next unless my $levels = $event->{$k};

      $event->{$k} = {
         map { $convert->{$_} => $levels->{$_} } keys %$convert
      };
   }

   if( $phase eq "initial" ) {
      my $levels = $event->{content};

      $self->{levels}{$_} = $levels->{$_} for keys %$levels;
   }
   elsif( $phase eq "forward" ) {
      my $newlevels = $event->{content};
      my $oldlevels = $event->{prev_content};

      my %changes;
      foreach ( keys %$newlevels ) {
         $self->{levels}{$_} = $newlevels->{$_};

         $changes{"level.$_"} = [ $oldlevels->{$_}, $newlevels->{$_} ]
            if !defined $oldlevels->{$_} or $oldlevels->{$_} != $newlevels->{$_};
      }

      my $member = $self->{members_by_userid}{$event->{user_id}};
      $self->maybe_invoke_event( on_state_changed =>
         $member, $event, %changes
      );
   }
   elsif( $phase eq "backward" ) {
      my $newlevels = $event->{content};
      my $oldlevels = $event->{prev_content};

      my %changes;
      foreach ( keys %$newlevels ) {
         $changes{"level.$_"} = [ $newlevels->{$_}, $oldlevels->{$_} ]
            if !defined $oldlevels->{$_} or $oldlevels->{$_} != $newlevels->{$_};
      }

      my $member = $self->{back_members_by_userid}{$event->{user_id}};
      $self->maybe_invoke_event( on_back_state_changed =>
         $member, $event, %changes
      );
   }
}

{
   foreach my $phase (qw( initial forward backward )) {
      no strict 'refs';

      *{"_handle_roomevent_ops_levels_${phase}"} = sub {
         shift->${\"_handle_generic_level"}( $phase, ops =>
            { map {; "${_}_level", $_ } qw( ban kick redact ) }, @_
         );
      };

      *{"_handle_roomevent_send_event_level_${phase}"} = sub {
         shift->${\"_handle_generic_level"}( $phase, send_event =>
            { level => "send_event" }, @_
         );
      };

      *{"_handle_roomevent_add_state_level_${phase}"} = sub {
         shift->${\"_handle_generic_level"}( $phase, add_state =>
            { level => "add_state" }, @_
         );
      };
   }
}

sub levels
{
   my $self = shift;
   return %{ $self->{levels} };
}

=head2 $room->change_levels( %levels )->get

Performs a room levels change, submitting new values for the given keys while
leaving other keys unchanged.

=cut

sub change_levels
{
   my $self = shift;
   my %levels = @_;

   # Delete null changes
   foreach ( keys %levels ) {
      delete $levels{$_} if $self->{levels}{$_} == $levels{$_};
   }

   my %events;

   # These go in their own event with the content key 'level'
   foreach (qw( send_event add_state )) {
      $events{"${_}_level"} = { level => $levels{$_} } if exists $levels{$_};
   }

   # These go in an 'ops_levels' event
   foreach (qw( ban kick redact )) {
      $events{ops_levels}{"${_}_level"} = $levels{$_} if exists $levels{$_};
   }

   # Fill in remaining 'ops_levels' keys
   if( $events{ops_levels} ) {
      $events{ops_levels}{"${_}_level"} //= $self->{levels}{$_} for qw( ban kick redact );
   }

   Future->needs_all(
      map { $self->_do_PUT_json( "/state/m.room.$_", $events{$_} ) } keys %events
   )->then_done();
}

=head2 @members = $room->members

Returns a list of member structs containing the currently known members of the
room, in no particular order. This list will include users who are not yet
members of the room, but simply have been invited.

=cut

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

   my $target_member;
   if( $old ) {
      $target_member = $members->{$user_id} or
         warn "ARGH: roomevent_member with unknown user id '$user_id'" and return;
   }
   else {
      my $user = $self->{matrix}->_get_or_make_user( $user_id );
      $target_member = $members->{$user_id} ||=
         Member( $user, undef, undef );
   }

   my %changes;
   foreach (qw( membership displayname )) {
      next if !defined $old->{$_} and !defined $new->{$_};
      next if defined $old->{$_} and defined $new->{$_} and $old->{$_} eq $new->{$_};

      $changes{$_} = [ $old->{$_}, $new->{$_} ];
      $target_member->$_ = $new->{$_};
   }

   my $member = $members->{$event->{user_id}}; # == the user making the change

   $self->maybe_invoke_event( $name => $member, $event, $target_member, %changes );

   if( !$new ) {
      delete $members->{$user_id};
   }
}

sub members
{
   my $self = shift;
   return values %{ $self->{members_by_userid} };
}

=head2 @members = $room->joined_members

Returns the subset of C<all_members> who actually in the C<"join"> state -
i.e. are not invitees, or have left.

=cut

sub joined_members
{
   my $self = shift;
   return grep { $_->membership eq "join" } $self->members;
}

=head2 $level = $room->member_level( $user_id )

Returns the current cached value for the power level of the given user ID, or
the default value if no specific value exists for the given ID.

=cut

sub _handle_roomevent_power_levels_initial
{
   my $self = shift;
   my ( $event ) = @_;

   my $levels = $event->{content};
   $self->{level_by_userid} = { %$levels };
}

sub _handle_roomevent_power_levels_forward
{
   my $self = shift;
   my ( $event ) = @_;

   my $levels = $event->{content};
   $self->{level_by_userid} = { %$levels };

   $self->_handle_roomevent_power_levels( on_membership =>
      $event, $self->{members_by_userid}, $event->{prev_content}, $levels
   );
}

sub _handle_roomevent_power_levels_backward
{
   my $self = shift;
   my ( $event ) = @_;

   $self->_handle_roomevent_power_levels( on_back_membership =>
      $event, $self->{back_members_by_userid}, $event->{content}, $event->{prev_content}
   );
}

sub _handle_roomevent_power_levels
{
   my $self = shift;
   my ( $name, $event, $members, $old, $new ) = @_;

   my $change_member = $members->{$event->{user_id}};

   foreach my $user_id ( keys %$new ) {
      next if $user_id eq "default";

      my $newlevel = $new->{$user_id} // $new->{default};
      my $oldlevel = $old->{$user_id} // $old->{default};
      next if defined $newlevel and defined $oldlevel and $newlevel == $oldlevel;

      my $member = $members->{$user_id} or next;

      $self->maybe_invoke_event( $name =>
         $change_member, $event, $member, level => [ $oldlevel, $newlevel ]
      );
   }

   foreach my $user_id ( keys %$old ) {
      next if exists $new->{$user_id};

      my $newlevel = $new->{$user_id} // $new->{default};
      my $oldlevel = $old->{$user_id} // $old->{default};
      next if defined $newlevel and defined $oldlevel and $newlevel == $oldlevel;

      my $member = $members->{$user_id} or next;

      $self->maybe_invoke_event( $name =>
         $change_member, $event, $member, level => [ $oldlevel, $newlevel ]
      );
   }
}

sub member_level
{
   my $self = shift;
   my ( $user_id ) = @_;

   return $self->{level_by_userid}{$user_id} // $self->{level_by_userid}{default};
}

=head2 $room->change_member_levels( %levels )->get

Performs a member power level change, submitting new values for user IDs to
the home server. As there is no server API to make individual mutations, this
is done by taking the currently cached values, applying the changes given by
the C<%levels> key/value list, and submitting the resulting whole as the new
value for the C<m.room.power_levels> room state.

The C<%levels> key/value list should provide new values for keys giving user
IDs, or the special user ID of C<default> to change the overall default value
for users not otherwise mentioned. Setting the special value of C<undef> for a
user ID will remove that ID from the set, reverting them to the default.

=cut

sub change_member_levels
{
   my $self = shift;

   my %levels = %{ $self->{level_by_userid} };
   while( @_ ) {
      my $user_id = shift;
      my $value   = shift;

      if( defined $value ) {
         $levels{$user_id} = $value;
      }
      elsif( $user_id ne "default" ) {
         delete $levels{$user_id};
      }
      else {
         croak "Cannot delete the 'default' power_level";
      }
   }

   $self->_do_PUT_json( "/state/m.room.power_levels", \%levels )
      ->then_done();
}

=head2 $room->leave->get

Requests to leave the room. After this completes, the user will no longer be
a member of the room.

=cut

sub leave
{
   my $self = shift;
   $self->_do_POST_json( "/leave", {} );
}

=head2 $room->invite( $user_id )->get

Sends an invitation for the user with the given User ID to join the room.

=cut

sub invite
{
   my $self = shift;
   my ( $user_id ) = @_;

   $self->_do_POST_json( "/invite", { user_id => $user_id } )
      ->then_done();
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

   $self->_do_POST_json( "/send/m.room.message", \%args )
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

   croak "Cannot paginate_messages any further since we're already at the start"
      if $from eq "START";

   # Since we're now doing pagination, we'll need a second set of member
   # objects
   $self->{back_members_by_userid} //= {
      pairmap { $a => Member( $b->user, $b->displayname, $b->membership ) } %{ $self->{members_by_userid} }
   };
   $self->{back_aliases_by_hs} //= {
      pairmap { $a => [ @$b ] } %{ $self->{aliases_by_hs} }
   };

   my $f = $self->_do_GET_json( "/messages",
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
            $self->{matrix}->log( "TODO: Handle room pagination event $subtype" );
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

sub _handle_roomevent_create_backward
{
   my $self = shift;

   # Stop now
   $self->{pagination_token} = "START";
}

sub _handle_roomevent_message_forward
{
   my $self = shift;
   my ( $event ) = @_;

   my $user_id = $event->{user_id};
   my $member = $self->{members_by_userid}{$user_id} or
      warn "TODO: Unknown member '$user_id' for forward message" and return;

   $self->maybe_invoke_event( on_message => $member, $event->{content}, $event );
}

sub _handle_roomevent_message_backward
{
   my $self = shift;
   my ( $event ) = @_;

   my $user_id = $event->{user_id};
   my $member = $self->{back_members_by_userid}{$user_id} or
      warn "TODO: Unknown member '$user_id' for backward message" and return;

   $self->maybe_invoke_event( on_back_message => $member, $event->{content}, $event );
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
