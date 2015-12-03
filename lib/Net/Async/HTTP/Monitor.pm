use 5.006;    # our
use strict;
use warnings;

package Net::Async::HTTP::Monitor;

our $VERSION = '0.001000';

# ABSTRACT: Stalk a HTTP URI efficiently and invoke code when it changes

# AUTHORITY
use IO::Async::Timer::Periodic;

use subs qw( on_updated_chunk on_updated on_error on_no_content );

use Class::Tiny qw( http uri on_updated_chunk on_updated on_no_content on_error ), {
  initial_request => sub {
    my ($self) = @_;

    ( { $self->http->_make_request_for_uri( $self->uri ) } )->{request};
  },
  refresh_interval => sub { 60 },
  first_interval   => sub { 0 },
  timer            => sub {
    my ($self) = @_;
    require IO::Async::Timer::Periodic;
    my $timer = IO::Async::Timer::Periodic->new(
      interval       => $self->refresh_interval,
      first_interval => $self->first_interval,
      on_tick        => sub { $self->_on_tick(@_) },
    );
    IO::Async::Notifier::add_child( $self, $timer );
    $timer;
  }
};

sub BUILD {
  my ($self) = @_;
  die "Must specify either a URI or an initial request"
    unless exists $self->{uri}
    or exists $self->{initial_request};
  die 'A N:A:Http compatible UA must be passed as `http`'
    unless exists $self->{http};
}

sub log_info(&@);
sub log_debug(&@);
sub log_trace(&@);

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

#### This bodging is because there's no practical way
#    to make Class::Tiny work with a parent class of IO::Async::Notifier
#    so I'm just rolin' with it.
sub children   { return ( $_[0]->timer ) }
sub parent     { IO::Async::Notifier::parent( $_[0] ) }
sub loop       { IO::Async::Notifier::loop( $_[0] ) }
sub __set_loop { IO::Async::Notifier::__set_loop( $_[0] ) }

sub start {
  my ( $self, $loop ) = @_;
  log_trace { "starting timer $self" };
  $self->timer->start;
}

sub _on_tick {
  my ($self) = @_;
  log_trace { "$self tick" };
  if ( not $self->{last_request} ) {
    return $self->_primary_query;
  }
  return $self->_refresh_query;
}

sub _dispatch_request {
  my ( $self, $request ) = @_;
  return if $self->{active};
  $self->{active}       = 1;
  $self->{last_request} = $request;
  $self->http->do_request(
    request   => $self->{last_request},
    on_header => sub {
      $self->{last_response} = $_[0];
      $self->on_header(@_);
    },
    on_response => sub {
      $self->{active} = 0;
      $self->on_response(@_);
    },
    on_error => sub {
      $self->{active} = 0;
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

  my $req = $self->{last_request}->clone;

  return $req if $self->{last_response}->code =~ /\A[34]0\d\z/;

  if ( my $date = $self->{last_response}->header('date') ) {
    $req->header( 'if-modified-since', $date );
  }
  return $req;
}

sub on_updated_chunk {
  my ( $self, $response, @chunk ) = @_;
  return $self->{on_updated_chunk}->( $response, @chunk ) if exists $self->{on_updated_chunk};
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
  return $self->{on_updated}->($response) if exists $self->{on_updated};
}

sub on_no_content {
  my ( $self, $response ) = @_;
  log_trace { "on_no_content" };
  return $self->{on_no_content}->($response) if exists $self->{on_no_content};
}

sub on_response {
  my ( $self, $response ) = @_;
  log_trace { "on_response" };
  return $self->{on_response}->($response) if exists $self->{on_response};
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
  return $self->{on_error}->($error) if exists $self->{on_error};
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

