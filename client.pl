#!/usr/bin/perl

use strict;
use warnings;

use Try::Tiny;

use IO::Async::Loop;

use Net::Async::Matrix;

use Tickit::Async;
use Tickit::Console 0.07; # time/datestamp format
use Tickit::Widgets qw( FloatBox Frame GridBox Static );
Tickit::Widget::Frame->VERSION( '0.31' ); # bugfix to linetypes in constructor
use String::Tagged 0.10; # ->append_tagged chainable

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
      ->apply_tag( 0, 5, fg => "blue" ),
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
));

sub new_room
{
   my ( $room ) = @_;

   my $floatbox;

   # Until Tickit::Widget::Tabbed supports a 'tab_class' argument to add_tab,
   # we'll have to cheat
   no warnings 'redefine';
   local *Tickit::Widget::Tabbed::TAB_CLASS = sub { "RoomTab" };

   my $roomtab = $console->add_tab(
      name => $room->room_id,
      make_widget => sub {
         my ( $scroller ) = @_;

         return $floatbox = Tickit::Widget::FloatBox->new(
            base_child  => $scroller,
         );
      },
      on_line => sub {
         my ( $tab, $line ) = @_;
         if( $line =~ s{^/}{} ) {
            do_command( $line, $tab );
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
   );
}

if( defined $config->{user_id} ) {
   $matrix->configure(
      user_id      => $config->{user_id},
      access_token => $config->{access_token},
   );

   $matrix->start;
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
   my ( $localpart ) = @_;

   $matrix->register( $localpart )->then( sub {
      my ( $user_id, $access_token ) = @_;

      ::log( "Received new user_id $user_id" );

      my $config;
      $config = YAML::LoadFile( $CONFIG ) if -f $CONFIG;
      $config->{user_id} = $user_id;
      $config->{access_token} = $access_token;
      $config->{server} //= $SERVER;

      YAML::DumpFile( $CONFIG, $config );

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

      my $room     = $args{room};
      my $floatbox = $args{floatbox};

      $self->{presence_table} = my $presence_table = Tickit::Widget::GridBox->new(
         col_spacing => 1,
      );

      $self->{presence_userids} = \my @presence_userids;
      $presence_table->add( 0, 0, Tickit::Widget::Static->new( text => "Name" ) );
      $presence_table->add( 0, 1, Tickit::Widget::Static->new( text => "Since" ) );

      my $presence_float = $floatbox->add_float(
         child => Tickit::Widget::Frame->new(
            style => {
               linetype => "none",
               linetype_left => "single",

               frame_fg => "white", frame_bg => "purple",
            },
            child => $presence_table,
         ),

         top => 0, bottom => -1, right => -1,
         left => -40,

         # Initially hidden
         hidden => 1,
      );

      my $visible = 0;
      $self->bind_key( 'F2' => sub {
         $visible ? ( $presence_float->hide, $visible = 0 )
                  : ( $presence_float->show, $visible = 1 );
      });

      $room->configure(
         on_synced_state => sub {
            $self->set_name( $room->name );
         },

         on_message => sub {
            my ( undef, $member, $content ) = @_;

            $self->append_line( build_message( $content, $member ),
               indent => 10,
               time   => $content->{hsob_ts} / 1000,
            );
         },
         on_membership => sub {
            my ( undef, $member, %changes ) = @_;

            # Ignore invited users
            return if $member->membership eq "invite";

            $self->update_member_presence( $member );

            # TODO - display this as a join/leave event in the message history.
            # However, it's currently hard to do that during historic backfill at
            # initialSync time. :(
         },
         on_presence => sub {
            my ( undef, $member, %changes ) = @_;
            $self->update_member_presence( $member );
         },
      );
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

      if( defined $rowidx and $member->membership eq "leave" ) {
         splice @$presence_userids, $rowidx, 1, ();
         $presence_table->delete_row( $rowidx+1 );
         return;
      }

      my ( $name, $since );
      if( defined $rowidx ) {
         ( $name, $since ) = $presence_table->get_row( $rowidx+1 );
      }
      else {
         $presence_table->append_row( [
            $name = Tickit::Widget::Static->new( text => "" ),
            $since = Tickit::Widget::Static->new( text => "" ),
         ] );
         push @$presence_userids, $user_id;
      }

      $name->set_style( fg => $PRESENCE_STATE_TO_COLOUR{$user->presence} )
         if defined $user->presence;
      $name->set_text(
         defined $member->displayname ? $member->displayname : "[".$user->user_id."]"
      );

      if( defined $user->last_active ) {
         $since->set_text( strftime "%Y/%m/%d %H:%M", localtime $user->last_active );
      }
      else {
         $since->set_text( "    --    " );
      }
   }

   sub build_message
   {
      my ( $content, $member ) = @_;

      my $s = String::Tagged->new;

      my $msgtype = $content->{msgtype};
      my $body    = $content->{body};

      if( $msgtype eq "m.text" ) {
         return $s
            ->append_tagged( "<", fg => "purple" )
            ->append( build_message_displayname( $member ) )
            ->append_tagged( "> ", fg => "purple" )
            ->append       ( $body );
      }
      elsif( $msgtype eq "m.emote" ) {
         return $s
            ->append_tagged( "* ", fg => "purple" )
            ->append( build_message_displayname( $member ) )
            ->append_tagged( " " )
            ->append       ( $body );
      }
      else {
         return $s
            ->append_tagged( "[" )
            ->append_tagged( $msgtype, fg => "yellow" )
            ->append_tagged( " from " )
            ->append( build_message_displayname( $member ) )
            ->append_tagged( "]: " )
            ->append       ( Data::Dump::pp $body );
      }
   }

   sub build_message_displayname
   {
      my ( $member ) = @_;

      if( defined $member->displayname ) {
         return String::Tagged->new
            ->append_tagged( $member->displayname, fg => "cyan" );
      }
      else {
         return String::Tagged->new
            ->append_tagged ( $member->user->user_id, fg => "grey" );
      }
   }
}
