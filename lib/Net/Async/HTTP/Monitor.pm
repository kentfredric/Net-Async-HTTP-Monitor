use 5.006;    # our
use strict;
use warnings;

package Net::Async::HTTP::Monitor;

our $VERSION = '0.001000';

# ABSTRACT: Stalk a HTTP URI efficiently and invoke code when it changes

# AUTHORITY
use Moo qw( has extends );
use IO::Async::Timer::Periodic;
use Safe::Isa qw( $_isa );

extends 'IO::Async::Notifier';

has http => ( is => 'ro', required  => 1 );
has uri  => ( is => 'ro', predicate => 1 );
has refresh_interval => ( is => ro =>, lazy => 1, default => sub { 60 } );
has first_interval   => ( is => ro =>, lazy => 1, default => sub { 0 } );

has initial_request => ( is => ro =>, lazy => 1, predicate => 1, default => sub { $_[0]->_uri_to_get( $_[0]->uri ) } );

__PACKAGE__->_add_sub_proxy('on_updated_chunk');
__PACKAGE__->_add_sub_proxy('on_updated');
__PACKAGE__->_add_sub_proxy('on_no_content');
__PACKAGE__->_add_sub_proxy('on_error');

has timer => (
  is      => ro =>,
  lazy    => 1,
  default => sub {
    my ($self) = @_;
    require IO::Async::Timer::Periodic;
    my $timer = IO::Async::Timer::Periodic->new(
      interval       => $self->refresh_interval,
      first_interval => $self->first_interval,
      on_tick        => sub { $self->_on_tick(@_) },
    );
    $self->add_child($timer);
    $timer;
  },
);

has '_active'        => ( is => 'rwp', init_arg => undef );
has '_last_request'  => ( is => 'rwp', init_arg => undef, predicate => 1 );
has '_last_response' => ( is => 'rwp', init_arg => undef, predicate => 1 );

# Logging functions constructed later
## no critic (ProhibitSubroutinePrototypes)
sub log_info(&@);
sub log_debug(&@);
sub log_trace(&@);
## use critic

sub start {
  my ($self) = @_;
  log_trace { "starting timer $self" };
  $self->timer->start;
}

sub on_header {
  my ( $self, $response ) = @_;
  log_trace { 'on_header' };
  return sub {
    $self->on_updated_chunk( $response, @_ );
    if (@_) {
      $response->add_content(@_);
    }
    else {
      return $response;
    }
  };
}

sub on_response {
  my ( $self, $response ) = @_;
  log_trace { 'on_response' };

  $response->is_success and return $self->on_updated($response);

  '304' eq $response->code and return $self->on_no_content($response);
}

sub BUILD {
  my ($self) = @_;
  die 'Either attribute `uri` ( A HTTP URI )' .    #
    ' or `request` ( an HTTP::Request ) is required'
    unless $self->has_uri or $self->has_initial_request;
}

# This evil code has to delete all the attributes Moo picks up
# or IO::A:Notifier will cry about extra arguments.
sub FOREIGNBUILDARGS {
  ( ref $_[1] ) ? %{ $_[1] } : @_[ 1 .. $#_ ];
}
sub configure_unknown { return }    # disable croak on unknown params

sub _add_sub_proxy {
  my ( $class, $name ) = @_;
  my $attr_name = "_$name";
  has $attr_name => ( is => ro =>, init_arg => $name, predicate => 1 );
  my $pred_method = "_has_$name";
  my $code        = sub {
    log_trace { $name };
    $_[0]->$pred_method() and return $_[0]->$attr_name()->( @_[ 1 .. $#_ ] );
  };
  no strict 'refs';                 ## no critic (ProhibitNoStrict)
  *{ $class . q[::] . $name } = $code;
}

BEGIN {

  if ( $INC{'Log/Contextual.pm'} ) {
    ## Hide from autoprereqs
    require 'Log/Contextual/WarnLogger.pm';    ## no critic (Modules::RequireBarewordIncludes)
    my $deflogger = Log::Contextual::WarnLogger->new( { env_prefix => 'NAHTTP_MONITOR', } );
    Log::Contextual->import( 'log_info', 'log_debug', 'log_trace', '-default_logger' => $deflogger );
  }
  else {
    require Carp;
    *log_info  = sub (&@) { Carp::carp( $_[0]->() ) };
    *log_debug = sub (&@) { };
    *log_trace = sub (&@) { };
  }
}

sub _on_tick {
  my ($self) = @_;
  log_trace { "$self tick" };
  return $self->_primary_query if not $self->_has_last_request;
  return $self->_refresh_query;
}

sub _uri_to_get {
  my ($uri) = $_[1];
  if ( !$uri->$_isa('URI') ) {
    die '`uri` must be a URI or a scalar' if ref $uri;
    require URI;
    $uri = URI->new($uri);
  }
  require HTTP::Request;
  my $request = HTTP::Request->new( 'GET', $uri );
  $request->protocol('HTTP/1.1');
  $request->header( Host => $uri->host );

  if ( defined $uri->userinfo ) {
    $request->authorization_basic( split m/:/, $uri->userinfo, 2 );    ## no critic (RegularExpressions)
  }
  return $request;
}

sub _dispatch_request {
  my ( $self, $request ) = @_;
  return if !!$self->_active;
  $self->_set__active(1);
  $self->_set__last_request($request);
  $self->http->do_request(
    request   => $request,
    on_header => sub {
      $self->_set__last_response( $_[0] );
      $self->on_header(@_);
    },
    on_response => sub {
      $self->_set__active(0);
      $self->on_response(@_);
    },
    on_error => sub {
      $self->_set__active(0);
      $self->on_error(@_);
    },
  );
}

sub _primary_query {
  my ($self) = @_;
  log_trace { '_primary_query' };
  $self->_dispatch_request( $self->initial_request );
}

sub _refresh_query {
  my ($self) = @_;
  log_trace { '_refresh_query' };
  $self->_dispatch_request( $self->_refresh_request );
}

sub _refresh_request {
  my ($self) = @_;
  log_trace { '_refresh_request' };

  my $req  = $self->_last_request->clone;
  my $resp = $self->_last_response;

  return $req if $resp->code =~ / \A [34]0\d \z/sx;

  if ( my $date = $resp->header('date') ) {
    $req->header( 'if-modified-since', $date );
  }
  return $req;
}

1;

=head1 SYNOPSIS

  use IO::Async::Loop;
  use Net::Async::HTTP::Monitor;

  my $loop = IO::Async::Loop->new();
  my $http = Net::Async::HTTP->new();

  $loop->add($http);

  my $monitor = Net::Async::HTTP::Monitor->new(
    http             => $http,
    uri              => 'http://example.org/some-infrequently-changed-page',
    refresh_interval => 60,
    on_new_content   => sub {
      my ($request) = @_;

      # requests be made with various caching options
      # prioritizing to make use of if-not-modified-since and etag and misc caching
      # stuff
    },
  );

  $monitor->start;

  $loop->add($monitor);

  $loop->run;

