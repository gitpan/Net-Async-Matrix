#!/usr/bin/perl

use strict;
use warnings;

use Try::Tiny;

use IO::Async::Loop;

use Net::Async::Matrix;

use Tickit::Async;
use Tickit::Console 0.07; # time/datestamp format
use Tickit::Widgets qw( FloatBox Frame GridBox ScrollBox Static VBox );
Tickit::Widget::Frame->VERSION( '0.31' ); # bugfix to linetypes in constructor
use String::Tagged 0.10; # ->append_tagged chainable

# Presence list scrolling requires Tickit 0.48 to actually work properly
use Tickit 0.48;

use Getopt::Long;

use YAML;
use Data::Dump 'pp';

my $CONFIG = "client.yaml";

GetOptions(
   "C|config=s" => \$CONFIG,
   "S|server=s" => \my $SERVER,
   "ssl+"       => \my $SSL,
   "D|dump-requests" => \my $DUMP_REQUESTS,
) or exit 1;

my $loop = IO::Async::Loop->new;

my $console = Tickit::Console->new(
   timestamp_format => String::Tagged->new_tagged( "%H:%M ", fg => undef )
      ->apply_tag( 0, 5, fg => "hi-blue" ),
   datestamp_format => String::Tagged->new_tagged( "-- day is now %Y/%m/%d --",
      fg => "grey" ),
);

my $matrix;

if( $DUMP_REQUESTS ) {
   open my $requests_fh, ">>", "requests.log" or die "Cannot write requests.log - $!";
   $requests_fh->autoflush;

   require Net::Async::HTTP;
   require Class::Method::Modifiers;

   Class::Method::Modifiers::install_modifier( "Net::Async::HTTP",
      around => _do_request => sub {
         my ( $orig, $self, %args ) = @_;
         my $request = $args{request};

         my $request_uri = $request->uri;
         return $orig->( $self, %args )
            ->on_done( sub {
               my ( $response ) = @_;

               my $data = eval { pp JSON::decode_json( $response->content ) };

               print $requests_fh "Response from $request_uri:\n";
               print $requests_fh "  $_\n" for split m/\n/, $data // $response->content;
            });
      }
   );
}

my %PRESENCE_STATE_TO_COLOUR = (
   offline     => "grey",
   unavailable => "orange",
   online      => "green",
);

# Eugh...
my $globaltab;

sub append_line_colour
{
   my ( $fg, $text ) = @_;

   $globaltab->append_line(
      String::Tagged->new( $text )->apply_tag( 0, -1, fg => $fg )
   );
}

sub log
{
   my ( $line ) = @_;
   append_line_colour( green => ">> $line" );
}

$globaltab = $console->add_tab(
   name => "Global",
   on_line => sub {
      my ( $tab, $line ) = @_;
      do_command( $line, $globaltab );
   },
);

my $config;
if( -f $CONFIG ) {
   $config = YAML::LoadFile( $CONFIG );
   $SERVER //= $config->{server};
   $SSL    //= $config->{ssl};
}

$SERVER //= "localhost:8080";

my $tickit = Tickit::Async->new( root => $console );
$loop->add( $tickit );

my %tabs_by_roomid;

$loop->add( $matrix = Net::Async::Matrix->new(
   server => $SERVER,
   ( $SSL ? (
      SSL             => 1,
      SSL_verify_mode => 0,
   ) : () ),

   on_log => \&log,

   on_presence => sub {
      my ( $self, $user, %changes ) = @_;

      if( exists $changes{presence} ) {
         append_line_colour( yellow => " * ".make_username($user)." now " . $user->presence );
      }
      elsif( exists $changes{displayname} ) {
         append_line_colour( yellow => " * $changes{displayname}[0] is now called ".make_username($user) );
      }
   },
   on_room_new => sub {
      my ( $self, $room ) = @_;
      new_room( $room );
   },
   on_room_del => sub {
      my ( $self, $room ) = @_;
      my $roomtab = delete $tabs_by_roomid{$room->room_id} or return;

      $console->remove_tab( $roomtab );
   },
   on_error => sub {
      my ( $self, $failure, $name ) = @_;

      append_line_colour( red => "Error: $failure" );

      if( $name eq "http" ) {
         my ( undef, undef, undef, $response, $request ) = @_;
         append_line_colour( red => "  ".$request->uri->path_query );
         append_line_colour( red => "  ".$response->content );
      }
   },

   on_invite => sub {
      my ( $self, $event ) = @_;

      $globaltab->append_line( String::Tagged->new
         ->append_tagged( " ** " )
         ->append_tagged( $event->{inviter}, fg => "grey" )
         ->append_tagged( " invites you to " )
         ->append_tagged( $event->{room_id}, fg => "cyan" )
      );

      # TODO: consider whether we should look up user displayname, room name,
      # etc...
   },
));

sub new_room
{
   my ( $room ) = @_;

   my $floatbox;
   my $headline;

   # Until Tickit::Widget::Tabbed supports a 'tab_class' argument to add_tab,
   # we'll have to cheat
   no warnings 'redefine';
   local *Tickit::Widget::Tabbed::TAB_CLASS = sub { "RoomTab" };

   my $roomtab = $console->add_tab(
      name => $room->room_id,
      make_widget => sub {
         my ( $scroller ) = @_;

         my $vbox = Tickit::Widget::VBox->new;

         $vbox->add( $headline = Tickit::Widget::Static->new(
               text => "",
               style => { bg => "blue" },
            ),
            expand => 0
         );
         $vbox->add( $scroller, expand => 1 );

         return $floatbox = Tickit::Widget::FloatBox->new(
            base_child  => $vbox,
         );
      },
      on_line => sub {
         my ( $tab, $line ) = @_;
         if( $line =~ s{^/}{} ) {
            my ( $cmd, @args ) = split m/\s+/, $line;
            if( my $code = $tab->can( "cmd_$cmd" ) ) {
               $room->adopt_future( $tab->$code( @args ) );
            }
            else {
               do_command( $line, $tab );
            }
         }
         else {
            $room->adopt_future( $room->send_message( $line ) );
         }
      },
   );
   $tabs_by_roomid{$room->room_id} = $roomtab;

   $roomtab->_setup(
      room     => $room,
      floatbox => $floatbox,
      headline => $headline,
   );
}

if( defined $config->{user_id} ) {
   print STDERR "Logging in as $config->{user_id}...\n";
   $matrix->login(
      map { $_ => $config->{$_} } qw( user_id password access_token )
   )->get;
}

$SIG{__WARN__} = sub {
   my $msg = join " ", @_;
   append_line_colour( orange => join " ", @_ );
};

$tickit->run;

sub make_username
{
   my ( $user ) = @_;

   if( defined $user->displayname ) {
      return "${\$user->displayname} (${\$user->user_id})";
   }
   else {
      return $user->user_id;
   }
}

## Command handlers

my $cmd_f;
sub do_command
{
   my ( $line, $tab ) = @_;

   # For now all commands are simple methods on __PACKAGE__
   my ( $cmd, @args ) = split m/\s+/, $line;

   $tab->append_line(
      String::Tagged->new( '$ ' . join " ", $cmd, @args )
         ->apply_tag( 0, -1, fg => "cyan" )
   );

   my $method = "cmd_$cmd";
   $cmd_f = Future->call( sub { __PACKAGE__->$method( @args ) } )
      ->on_done( sub {
         my @result = @_;
         $tab->append_line( $_ ) for @result;

         undef $cmd_f;
      })
      ->on_fail( sub {
         my ( $failure ) = @_;

         $tab->append_line(
            String::Tagged->new( "Error: $failure" )
               ->apply_tag( 0, -1, fg => "red" )
         );

         undef $cmd_f;
      });
}

sub cmd_register
{
   shift;
   my ( $localpart, @args ) = @_;

   my %args = ( user_id => $localpart );
   while( @args ) {
      for( shift @args ) {
         m/^--(.*)$/ and
            $args{$1} = shift @args, last;

         $args{password} = $_;
      }
   }

   $matrix->register( %args )->then( sub {
      ::log( "Registered" );
      Future->done;
   });
}

sub cmd_login
{
   shift;
   my ( $user_id, @args ) = @_;

   my %args = ( user_id => $user_id );
   while( @args ) {
      for( shift @args ) {
         m/^--(.*)$/ and
            $args{$1} = shift @args, last;

         $args{password} = $_;
      }
   }

   $matrix->login( %args )->then( sub {
      ::log( "Logged in" );
      Future->done;
   });
}

sub cmd_dname_get
{
   shift;
   my ( $user_id ) = @_;

   $matrix->get_displayname( $user_id );
}

sub cmd_dname_set
{
   shift;
   my ( $name ) = @_;

   $matrix->set_displayname( $name )
      ->then_done( "Set" );
}

sub cmd_offline { shift; $matrix->set_presence( "offline", @_ )->then_done( "Set" ) }
sub cmd_busy    { shift; $matrix->set_presence( "unavailable", "Busy" )->then_done( "Set" ) }
sub cmd_away    { shift; $matrix->set_presence( "unavailable", "Away" )->then_done( "Set" ) }
sub cmd_online  { shift; $matrix->set_presence( "online", @_ )->then_done( "Set" ) }

sub cmd_plist
{
   shift;

   $matrix->get_presence_list->then( sub {
      my @users = @_;

      Future->done(
         +( map { make_username($_) . " - " . $_->presence } @users ),
         scalar(@users) . " users total"
      );
   });
}

sub cmd_pcache
{
   shift;

   my @users = values %{ $matrix->{users_by_id} };

   Future->done(
      +( map { make_username($_) . " - " . $_->presence } @users ),
      scalar(@users) . " users total (from cache)"
   );
}

sub cmd_invite
{
   shift;
   my ( $userid ) = @_;

   $matrix->invite_presence( $userid )->then_done( "Invited" );
}

sub cmd_drop
{
   shift;
   my ( $userid ) = @_;

   $matrix->drop_presence( $userid )->then_done( "Dropped" );
}

sub cmd_createroom
{
   shift;
   my ( $room_name ) = @_;

   $matrix->create_room( $room_name )->then( sub {
      my ( $response ) = @_;
      Future->done( pp($response) );
   });
}

sub cmd_join
{
   shift;
   my ( $room_name ) = @_;

   $matrix->join_room( $room_name )->then_done( "Joined" );
}

sub cmd_leave
{
   shift;
   my ( $roomid ) = @_;

   $matrix->leave_room( $roomid )->then_done( "Left" );
}

sub cmd_msg
{
   shift;
   my ( $roomid, @msg ) = @_;

   my $msg = join " ", @msg;
   $matrix->send_room_message( $roomid, $msg )->then_done(); # suppress output
}

package RoomTab {
   use base qw( Tickit::Console::Tab );

   use POSIX qw( strftime );

   sub _setup
   {
      my $self = shift;
      my %args = @_;

      my $room     = $self->{room} = $args{room};
      my $floatbox = $args{floatbox};

      $self->{headline} = $args{headline};

      $self->{presence_table} = my $presence_table = Tickit::Widget::GridBox->new(
         col_spacing => 1,
      );

      $self->{presence_userids} = \my @presence_userids;
      $presence_table->add( 0, 0, Tickit::Widget::Static->new( text => "Name" ) );
      $presence_table->add( 0, 1, Tickit::Widget::Static->new( text => "Since" ) );
      $presence_table->add( 0, 2, Tickit::Widget::Static->new( text => "Lvl" ) );

      my $presence_float = $floatbox->add_float(
         child => Tickit::Widget::Frame->new(
            style => {
               linetype => "none",
               linetype_left => "single",

               frame_fg => "white", frame_bg => "purple",
            },
            child => my $vbox = Tickit::Widget::VBox->new,
         ),

         top => 0, bottom => -1, right => -1,
         left => -44,

         # Initially hidden
         hidden => 1,
      );

      $vbox->add(
         Tickit::Widget::ScrollBox->new(
            child => $presence_table,
            vertical   => "on_demand",
            horizontal => 0,
         ),
         expand => 1,
      );

      $vbox->add(
         my $presence_summary = Tickit::Widget::Static->new( text => "" )
      );

      my $visible = 0;
      $self->bind_key( 'F2' => sub {
         $visible ? ( $presence_float->hide, $visible = 0 )
                  : ( $presence_float->show, $visible = 1 );
      });

      $room->configure(
         on_synced_state => sub {
            $self->set_name( $room->name );
            $self->update_headline;

            # Fetch initial presence state of users
            foreach my $member ( $room->joined_members ) {
               $self->update_member_presence( $member );
            }

            $presence_summary->set_text(
               sprintf "Total: %d users", scalar $room->joined_members
            );

            $room->paginate_messages( limit => 150 );
         },

         on_message => sub {
            my ( undef, $member, $content ) = @_;

            $self->append_line( format_message( $content, $member ),
               indent => 10,
               time   => $content->{hsob_ts} / 1000,
            );
         },
         on_back_message => sub {
            my ( undef, $member, $content ) = @_;

            $self->prepend_line( format_message( $content, $member ),
               indent => 10,
               time   => $content->{hsob_ts} / 1000,
            );
         },

         on_membership => sub {
            my ( undef, $action_member, $event, $target_member, %changes ) = @_;

            $self->update_member_presence( $target_member );

            if( $changes{membership} and ( $changes{membership}[1] // "" ) eq "invite" ) {
               $self->append_line( format_invite( $action_member, $target_member ),
                  time => $event->{ts} / 1000,
               );
            }
            elsif( $changes{membership} ) {
               # On a LEAVE event they no longer have a displayname
               $target_member->displayname = $changes{displayname}[0] if !defined $changes{membership}[1];

               $self->append_line( format_membership( $changes{membership}[1] // "leave", $target_member ),
                  time => $event->{ts} / 1000,
               );
            }
            elsif( $changes{displayname} ) {
               $self->append_line( format_displayname_change( $target_member, @{ $changes{displayname} } ) );
            }

            $presence_summary->set_text(
               sprintf "Total: %d users", scalar $room->joined_members
            );
         },
         on_back_membership => sub {
            my ( undef, $action_member, $event, $target_member, %changes ) = @_;

            if( $changes{membership} and ( $changes{membership}[0] // "" ) eq "invite" ) {
               $self->prepend_line( format_invite( $action_member, $target_member ),
                  time => $event->{ts} / 1000,
               );
            }
            elsif( $changes{membership} ) {
               # On a JOIN event they don't yet have a displayname
               $target_member->displayname = $changes{displayname}[0] if $changes{membership}[0] // '' eq "join";

               $self->prepend_line( format_membership( $changes{membership}[0] // "leave", $target_member ),
                  time => $event->{ts} / 1000,
               );
            }
            elsif( $changes{displayname} ) {
               $self->prepend_line( format_displayname_change( $target_member, reverse @{ $changes{displayname} } ),
                  time => $event->{ts} / 1000,
               );
            }
            elsif( $changes{level} ) {
               $self->prepend_line( format_memberlevel_change( $action_member, $target_member, $changes{level}[0] ),
                  time => $event->{ts} / 1000,
               );
            }
         },

         on_state_changed => sub {
            my ( undef, $member, $event, %changes ) = @_;

            if( $changes{name} ) {
               $self->append_line( format_name_change( $member, $changes{name}[1] ),
                  time => $event->{ts} / 1000,
               );
               $self->set_name( $room->name );
            }
            if( $changes{aliases} ) {
               $self->append_line( $_, time => $event->{ts} / 1000 )
                  for format_alias_changes( $member, @{ $changes{aliases} }[0,1] );
            }
            if( $changes{topic} ) {
               $self->append_line( format_topic_change( $member, $changes{topic}[1] ),
                  time => $event->{ts} / 1000,
               );
               $self->update_headline;
            }
            foreach ( map { m/^level\.(.*)/ ? ( $1 ) : () } keys %changes ) {
               $self->append_line( format_roomlevel_change( $member, $_, $changes{"level.$_"}[1] ),
                  time => $event->{ts} / 1000,
               );
            }
         },
         on_back_state_changed => sub {
            my ( undef, $member, $event, %changes ) = @_;

            if( $changes{name} ) {
               $self->prepend_line( format_name_change( $member, $changes{name}[0] ),
                  time => $event->{ts} / 1000,
               );
            }
            if( $changes{aliases} ) {
               $self->prepend_line( $_, time => $event->{ts} / 1000 )
                  for format_alias_changes( $member, @{ $changes{aliases} }[1,0] );

               $self->prepend_line( "EVENT ${\Data::Dump::pp $event}", time => $event->{ts} / 1000 );
            }
            if( $changes{topic} ) {
               $self->prepend_line( format_topic_change( $member, $changes{topic}[0] ),
                  time => $event->{ts} / 1000,
               );
            }
            foreach ( map { m/^level\.(.*)/ ? ( $1 ) : () } keys %changes ) {
               $self->prepend_line( format_roomlevel_change( $member, $_, $changes{"level.$_"}[0] ),
                  time => $event->{ts} / 1000,
               );
            }
         },

         on_presence => sub {
            my ( undef, $member, %changes ) = @_;
            $self->update_member_presence( $member );
         },
      );
   }

   sub update_headline
   {
      my $self = shift;
      my $room = $self->{room};

      $self->{headline}->set_text( $room->topic // "" );
   }

   sub update_member_presence
   {
      my $self = shift;
      my ( $member ) = @_;

      my $user = $member->user;
      my $user_id = $user->user_id;

      my $presence_userids = $self->{presence_userids};

      # Find an existing row if we can
      my $rowidx;
      $presence_userids->[$_] eq $user_id and $rowidx = $_, last
         for 0 .. $#$presence_userids;

      my $presence_table = $self->{presence_table};

      if( defined $rowidx and !defined $member->membership ) {
         splice @$presence_userids, $rowidx, 1, ();
         $presence_table->delete_row( $rowidx+1 );
         return;
      }

      my ( $w_name, $w_since, $w_power );
      if( defined $rowidx ) {
         ( $w_name, $w_since, $w_power ) = $presence_table->get_row( $rowidx+1 );
      }
      else {
         $presence_table->append_row( [
            $w_name  = Tickit::Widget::Static->new( text => "" ),
            $w_since = Tickit::Widget::Static->new( text => "" ),
            $w_power = Tickit::Widget::Static->new( text => "-", class => "level" ),
         ] );
         push @$presence_userids, $user_id;
      }

      $w_name->set_style( fg => $PRESENCE_STATE_TO_COLOUR{$user->presence} )
         if defined $user->presence;

      my $dname = defined $member->displayname ? $member->displayname : "[".$user->user_id."]";
      $dname = substr( $dname, 0, 17 ) . "..." if length $dname > 20;
      $w_name->set_text( $dname );

      if( defined $user->last_active ) {
         $w_since->set_text( strftime "%Y/%m/%d %H:%M", localtime $user->last_active );
      }
      else {
         $w_since->set_text( "    --    " );
      }

      if( defined( my $level = $self->{room}->member_level( $user_id ) ) ) {
         $w_power->set_text( $level );
         $w_power->set_style( fg => ( $level > 0 ) ? "yellow" : undef );
      }
      else {
         $w_power->set_text( "-" );
      }
   }

   sub format_message
   {
      my ( $content, $member ) = @_;

      my $s = String::Tagged->new;

      my $msgtype = $content->{msgtype};
      my $body    = $content->{body};

      if( $msgtype eq "m.text" ) {
         return $s
            ->append_tagged( "<", fg => "magenta" )
            ->append( format_displayname( $member ) )
            ->append_tagged( "> ", fg => "magenta" )
            ->append       ( $body );
      }
      elsif( $msgtype eq "m.emote" ) {
         return $s
            ->append_tagged( "* ", fg => "magenta" )
            ->append( format_displayname( $member ) )
            ->append_tagged( " " )
            ->append       ( $body );
      }
      else {
         return $s
            ->append_tagged( "[" )
            ->append_tagged( $msgtype, fg => "yellow" )
            ->append_tagged( " from " )
            ->append( format_displayname( $member ) )
            ->append_tagged( "]: " )
            ->append       ( Data::Dump::pp $body );
      }
   }

   sub format_membership
   {
      my ( $membership, $member ) = @_;

      my $s = String::Tagged->new;

      if( $membership eq "join" ) {
         return $s
            ->append_tagged( " => ", fg => "magenta" )
            ->append       ( format_displayname( $member, 1 ) )
            ->append       ( " " )
            ->append_tagged( "joined", fg => "green" );
      }
      elsif( $membership eq "leave" ) {
         return $s
            ->append_tagged( " <= ", fg => "magenta" )
            ->append       ( format_displayname( $member, 1 ) )
            ->append       ( " " )
            ->append_tagged( "left", fg => "red" );
      }
      else {
         return $s
            ->append       ( " [membership " )
            ->append_tagged( $membership, fg => "yellow" )
            ->append       ( "] " )
            ->append       ( format_displayname( $member, 1 ) );
      }
   }

   sub format_invite
   {
      my ( $inviting_member, $invitee ) = @_;

      return String::Tagged->new
         ->append       ( " ** " )
         ->append       ( format_displayname( $inviting_member ) )
         ->append       ( " invites " )
         ->append_tagged( $invitee->user->user_id, fg => "grey" );
   }

   sub format_displayname_change
   {
      my ( $member, $oldname, $newname ) = @_;

      my $s = String::Tagged->new
         ->append_tagged( "  ** ", fg => "magenta" );

      defined $oldname ?
         $s->append_tagged( $oldname, fg => "cyan" ) :
         $s->append_tagged( "[".$member->user->user_id."]", fg => "grey" );

      $s->append_tagged( " is now called " );

      defined $newname ?
         $s->append_tagged( $newname, fg => "cyan" ) :
         $s->append_tagged( "[".$member->user->user_id."]", fg => "grey" );

      return $s;
   }

   sub format_name_change
   {
      my ( $member, $name ) = @_;

      return String::Tagged->new
         ->append       ( " ** " )
         ->append       ( format_displayname( $member ) )
         ->append       ( " sets the room name to: " )
         ->append_tagged( $name, fg => "cyan" );
   }

   sub format_alias_changes
   {
      my ( $member, $old, $new ) = @_;

      my %deleted = map { $_ => 1 } @$old;
      delete $deleted{$_} for @$new;

      my %added   = map { $_ => 1 } @$new;
      delete $added{$_} for @$old;

      return
         ( map { String::Tagged->new
                        ->append_tagged( " # ", fg => "yellow" )
                        ->append       ( format_displayname( $member ) )
                        ->append       ( " adds room alias " )
                        ->append_tagged( $_, fg => "cyan" ) } sort keys %added ),
         ( map { String::Tagged->new
                        ->append_tagged( " # ", fg => "yellow" )
                        ->append       ( format_displayname( $member ) )
                        ->append       ( " deletes room alias " )
                        ->append_tagged( $_, fg => "cyan" ) } sort keys %deleted );
   }

   sub format_topic_change
   {
      my ( $member, $topic ) = @_;

      return String::Tagged->new
         ->append       ( " ** " )
         ->append       ( format_displayname( $member ) )
         ->append       ( " sets the topic to: " )
         ->append_tagged( $topic, fg => "cyan" );
   }

   sub format_roomlevel_change
   {
      my ( $member, $name, $level ) = @_;

      return String::Tagged->new
         ->append       ( " ** " )
         ->append       ( format_displayname( $member ) )
         ->append       ( " changes required level for " )
         ->append_tagged( $name, fg => "green" )
         ->append       ( " to " )
         ->append_tagged( $level, $level > 0 ? ( fg => "yellow" ) : () );
   }

   sub format_memberlevel_change
   {
      my ( $changing_member, $target_member, $level ) = @_;

      return String::Tagged->new
         ->append       ( " ** " )
         ->append       ( format_displayname( $changing_member ) )
         ->append       ( " changes power level of " )
         ->append       ( format_displayname( $target_member ) )
         ->append       ( " to " )
         ->append_tagged( $level, $level > 0 ? ( fg => "yellow" ) : () );
   }

   sub format_displayname
   {
      my ( $member, $full ) = @_;

      if( defined $member->displayname ) {
         my $s = String::Tagged->new
            ->append_tagged( $member->displayname, fg => "cyan" );

         $s->append_tagged( " [".$member->user->user_id."]", fg => "grey" ) if $full;

         return $s;
      }
      else {
         return String::Tagged->new
            ->append_tagged ( $member->user->user_id, fg => "grey" );
      }
   }

   sub cmd_me
   {
      my $self = shift;
      my ( @args ) = @_;

      my $text = join " ", @args;
      my $room = $self->{room};

      $room->send_message( type => "m.emote", body => $text );
   }

   sub cmd_leave
   {
      my $self = shift;

      my $room = $self->{room};
      $room->leave;
   }

   sub cmd_invite
   {
      my $self = shift;
      my ( $user_id ) = @_;

      my $room = $self->{room};

      $room->invite( $user_id );
   }

   sub cmd_level
   {
      my $self = shift;
      my $delete = $_[0] eq "-del" ? shift : 0;
      my ( $user_id, $level ) = @_;

      defined $level or $delete or
         Future->fail( "Require a power level, or -del" );

      my $room = $self->{room};

      $room->change_member_levels( $user_id => $level );
   }

   sub cmd_roomlevels
   {
      my $self = shift;

      my %levels;
      foreach (@_) {
         m/^(.*)=(\d+)$/ and $levels{$1} = $2;
      }

      my $room = $self->{room};
      $room->change_levels( %levels );
   }

   sub cmd_topic
   {
      my $self = shift;
      my $topic = join " ", @_; # TODO

      my $room = $self->{room};

      if( length $topic ) {
         $room->set_topic( $topic )
      }
      else {
         # TODO: Fetch and print the current topic
         Future->done;
      }
   }

   sub cmd_roomname
   {
      my $self = shift;
      my $name = join " ", @_; # TODO

      my $room = $self->{room};

      if( length $name ) {
         $room->set_name( $name )
      }
      else {
         # TODO: Fetch and print the current name
         Future->done;
      }
   }

   sub cmd_add_alias
   {
      my $self = shift;
      my ( $alias ) = @_;

      my $room_id = $self->{room}->room_id;

      $matrix->add_alias( $alias, $room_id );
   }

   sub cmd_delete_alias
   {
      my $self = shift;
      my ( $alias ) = @_;

      grep { $_ eq $alias } $self->{room}->aliases or
         return Future->fail( "$alias is not an alias of this room" );

      $matrix->delete_alias( $alias );
   }
}
