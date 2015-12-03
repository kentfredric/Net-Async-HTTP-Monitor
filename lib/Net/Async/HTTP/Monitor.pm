use 5.006;    # our
use strict;
use warnings;

package Net::Async::HTTP::Monitor;

our $VERSION = '0.001000';

# ABSTRACT: Stalk a HTTP URI efficiently and invoke code when it changes

# AUTHORITY

use IO::Async::Timer::Periodic;

use parent 'IO::Async::Notifier';

# Logging functions constructed later
sub log_info(&@);
sub log_debug(&@);
sub log_trace(&@);

# This this sort of crap you have to pull when you don't have a MOP
# and can't subclass with Moo/C:Tiny. Also, these would be really nice as macros :(

my ( $SET_ATTR, $GET_ATTR, $HAS_ATTR, $ATTR_TRUE, $MAYBE_CALL );    # Predeclared private subs
{
  my $DEFAULTS = {
    first_interval   => sub { 0 },
    refresh_interval => sub { 60 },
    initial_request  => sub { ( { $_[0]->http->_make_request_for_uri( $_[0]->uri ) } )->{request} },
    timer => sub {
      my ($self) = @_;
      require IO::Async::Timer::Periodic;
      my $timer = $self->$SET_ATTR(
        'timer' => IO::Async::Timer::Periodic->new(
          interval       => $self->refresh_interval,
          first_interval => $self->first_interval,
          on_tick        => sub { $self->_on_tick(@_) },
        )
      );
      $self->add_child($timer);
      $timer;
    },
  };
  $GET_ATTR = sub {
    exists $_[0]->{ __PACKAGE__ . q[/] . $_[1] } and return $_[0]->{ __PACKAGE__ . q[/] . $_[1] };
    return unless exists $DEFAULTS->{ $_[1] };
    return $_[0]->{ __PACKAGE__ . q[/] . $_[1] } = $DEFAULTS->{ $_[1] }->( $_[0] );
  };
  $SET_ATTR = sub { $_[0]->{ __PACKAGE__ . q[/] . $_[1] } = $_[2] };
  $HAS_ATTR = sub { exists $_[0]->{ __PACKAGE__ . q[/] . $_[1] } };
  $ATTR_TRUE = sub {
    exists $_[0]->{ __PACKAGE__ . q[/] . $_[1] }
      and return !!$_[0]->{ __PACKAGE__ . q[/] . $_[1] };
  };
  $MAYBE_CALL = sub {    # Ghostbusters
    exists $_[0]->{ __PACKAGE__ . q[/] . $_[1] }
      and return $_[0]->{ __PACKAGE__ . q[/] . $_[1] }->( @_[ 2 .. $#_ ] );
  };
}

sub http             { $_[0]->$GET_ATTR('http') }
sub uri              { $_[0]->$GET_ATTR('uri') }
sub timer            { $_[0]->$GET_ATTR('timer') }
sub first_interval   { $_[0]->$GET_ATTR('first_interval') }
sub refresh_interval { $_[0]->$GET_ATTR('refresh_interval') }
sub initial_request  { $_[0]->$GET_ATTR('initial_request') }

sub configure {
  my ( $self, %params ) = @_;
  exists $params{$_}
    and $self->$SET_ATTR( $_, delete $params{$_} )
    for qw( on_updated_chunk on_updated on_error on_no_content
    refresh_interval first_interval http uri reque);

  $self->$HAS_ATTR('http') or die 'Attribute `http` is required, and should be a NAHTTP client';
  $self->$HAS_ATTR('uri')
    or $self->$HAS_ATTR('request')
    or die 'Either attribute `uri` ( A HTTP URI ) or `request` ( an HTTP::Request ) is required';

  return $self->SUPER::configure(%params);
}

sub start {
  my ( $self ) = @_;
  log_trace { "starting timer $self" };
  $self->timer->start;
}

sub on_updated_chunk {
  my ( $self, $response, @chunk ) = @_;
  $self->$MAYBE_CALL( 'on_updated_chunk', $response, @chunk );
}

sub on_header {
  my ( $self, $response ) = @_;
  log_trace { "Header event" };
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

sub on_updated {
  my ( $self, $response ) = @_;
  log_trace { "on_updated" };
  $self->$MAYBE_CALL( 'on_updated', $response );
}

sub on_no_content {
  my ( $self, $response ) = @_;
  log_trace { "on_no_content" };
  $self->$MAYBE_CALL( 'on_no_content', $response );
}

sub on_response {
  my ( $self, $response ) = @_;
  log_trace { "on_response" };
  if ( $response->is_success ) {
    return $self->on_updated($response);
  }
  if ( $response->code eq '304' ) {
    return $self->on_no_content($response);
  }
}

sub on_error {
  my ( $self, $error ) = @_;
  log_trace { "on_error" };
  $self->$MAYBE_CALL( 'on_error', $error );
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
  return $self->_primary_query if not $self->$HAS_ATTR('last_request');
  return $self->_refresh_query;
}

sub _dispatch_request {
  my ( $self, $request ) = @_;
  return if $self->$ATTR_TRUE('active');
  $self->$SET_ATTR( 'active',       1 );
  $self->$SET_ATTR( 'last_request', $request );
  $self->http->do_request(
    request   => $request,
    on_header => sub {
      $self->$SET_ATTR( 'last_response', $_[0] );
      $self->on_header(@_);
    },
    on_response => sub {
      $self->$SET_ATTR( 'active', 0 );
      $self->on_response(@_);
    },
    on_error => sub {
      $self->$SET_ATTR( 'active', 0 );
      $self->on_error(@_);
    },
  );
}

sub _primary_query {
  my ($self) = @_;
  log_trace { "inital request" };
  $self->_dispatch_request( $self->initial_request );
}

sub _refresh_query {
  my ($self) = @_;
  log_trace { "refresh" };
  $self->_dispatch_request( $self->_refresh_request );
}

sub _refresh_request {
  my ($self) = @_;
  log_trace { "generate refresh request" };

  my $req  = $self->$GET_ATTR('last_request')->clone;
  my $resp = $self->$GET_ATTR('last_response');

  return $req if $resp->code =~ /\A[34]0\d\z/;

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

