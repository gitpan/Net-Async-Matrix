#!/usr/bin/perl

use strict;
use warnings;

use Try::Tiny;

use IO::Async::Loop;

use Net::Async::Matrix;

use Tickit::Async;
use Tickit::Console 0.06; # make_widget, ->bind_key
use Tickit::Widgets qw( FloatBox Frame GridBox Static );
Tickit::Widget::Frame->VERSION( '0.31' ); # bugfix to linetypes in constructor
use String::Tagged 0.09;

use Getopt::Long;

use YAML;
use Data::Dump 'pp';
use POSIX qw( strftime );

my $CONFIG = "client.yaml";
my $SERVER;

GetOptions(
   "C|config=s" => \$CONFIG,
   "S|server=s" => \$SERVER,
) or exit 1;

my $loop = IO::Async::Loop->new;

my $console = Tickit::Console->new;

my $matrix;

my %PRESENCE_STATE_TO_COLOUR = (
   offline     => "grey",
   unavailable => "orange",
   online      => "green",
);

# Eugh...
my $globaltab;

sub add_line_colour
{
   my ( $fg, $text ) = @_;

   $globaltab->add_line(
      String::Tagged->new( $text )->apply_tag( 0, -1, fg => $fg )
   );
}

sub log
{
   my ( $line ) = @_;
   add_line_colour( green => ">> $line" );
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
}

$SERVER //= "localhost:8080";

my $tickit = Tickit::Async->new( root => $console );
$loop->add( $tickit );

my %tabs_by_roomid;

$loop->add( $matrix = Net::Async::Matrix->new(
   server => $SERVER,
   on_log => \&log,
   on_presence => sub {
      my ( $self, $user, %changes ) = @_;

      if( exists $changes{state} ) {
         add_line_colour( yellow => " * ".make_username($user)." now " . $user->state );
      }
      elsif( exists $changes{displayname} ) {
         add_line_colour( yellow => " * $changes{displayname}[0] is now called ".make_username($user) );
      }
   },
   on_room_add => sub {
      my ( $self, $room ) = @_;
      new_room( $room );
   },
   on_room_del => sub {
      my ( $self, $room ) = @_;
      my $roomtab = delete $tabs_by_roomid{$room->room_id} or return;

      $roomtab->add_line( "** TODO: THIS TAB SHOULD NOW BE DELETED **" );
   },
   on_error => sub {
      my ( $self, $failure, $name ) = @_;

      add_line_colour( red => "Error: $failure" );

      if( $name eq "http" ) {
         my ( undef, undef, undef, $response, $request ) = @_;
         add_line_colour( red => "  ".$request->uri->path_query );
         add_line_colour( red => "  ".$response->content );
      }
   },
));

sub new_room
{
   my ( $room ) = @_;

   my $floatbox;
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
            $room->send_message( $line );
         }
      },
   );
   $tabs_by_roomid{$room->room_id} = $roomtab;

   my $presence_table = Tickit::Widget::GridBox->new(
      col_spacing => 1,
   );

   my @presence_userids;
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
   $roomtab->bind_key( 'F2' => sub {
      $visible ? ( $presence_float->hide, $visible = 0 )
               : ( $presence_float->show, $visible = 1 );
   });

   $room->configure(
      on_message => sub {
         my ( $self, $member, $content ) = @_;

         my $tstamp = strftime( "[%H:%M]", localtime $content->{hsob_ts} / 1000 );

         my $s = String::Tagged->new( "" );
         $s->append_tagged( $tstamp );
         $s->append_tagged( " <", fg => "purple" );
         if( defined $member->displayname ) {
            $s->append_tagged( $member->displayname, fg => "cyan" );
         }
         else {
            $s->append_tagged( $member->user_id, fg => "grey" );
         }
         $s->append_tagged( "> ", fg => "purple" );
         $s->append       ( $content->{body} );

         $roomtab->add_line( $s );
      },
      on_member => sub {
         my ( $self, $member, %changes ) = @_;

         # Ignore invited users
         return if $member->membership eq "invite";

         my $user_id = $member->user_id;

         # Find an existing row if we can
         my $rowidx;
         $presence_userids[$_] eq $user_id and $rowidx = $_, last
            for 0 .. $#presence_userids;

         if( defined $rowidx and $member->membership eq "leave" ) {
            splice @presence_userids, $rowidx, 1, ();
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
            push @presence_userids, $member->user_id;
         }

         $name->set_style( fg => $PRESENCE_STATE_TO_COLOUR{$member->state} )
            if defined $member->state;
         $name->set_text(
            defined $member->displayname ? $member->displayname : "[".$member->user_id."]"
         );

         if( defined $member->mtime ) {
            $since->set_text( strftime "%Y/%m/%d %H:%M", localtime $member->mtime );
         }
         else {
            $since->set_text( "    --    " );
         }
      },
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
   add_line_colour( orange => join " ", @_ );
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

   $tab->add_line(
      String::Tagged->new( '$ ' . join " ", $cmd, @args )
         ->apply_tag( 0, -1, fg => "cyan" )
   );

   my $method = "cmd_$cmd";
   $cmd_f = Future->call( sub { __PACKAGE__->$method( @args ) } )
      ->on_done( sub {
         my @result = @_;
         $tab->add_line( $_ ) for @result;

         undef $cmd_f;
      })
      ->on_fail( sub {
         my ( $failure ) = @_;

         $tab->add_line(
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
         +( map { make_username($_) . " - " . $_->state } @users ),
         scalar(@users) . " users total"
      );
   });
}

sub cmd_pcache
{
   shift;

   my @users = values %{ $matrix->{users_by_id} };

   Future->done(
      +( map { make_username($_) . " - " . $_->state } @users ),
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
