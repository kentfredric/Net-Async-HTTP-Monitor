use 5.006;    # our
use strict;
use warnings;

package Net::Async::HTTP::Monitor;

our $VERSION = '0.001000';

# ABSTRACT: Stalk a HTTP URI efficiently and invoke code when it changes

our $AUTHORITY = 'cpan:KENTNL'; # AUTHORITY

use IO::Async::Timer::Periodic;
use Safe::Isa qw( $_isa );

use parent 'IO::Async::Notifier';

# Logging functions constructed later
## no critic (ProhibitSubroutinePrototypes)
sub log_info(&@);
sub log_debug(&@);
sub log_trace(&@);
## use critic
#
# This this sort of crap you have to pull when you don't have a MOP
# and can't subclass with Moo/C:Tiny. Also, these would be really nice as macros :(

my ( $SET_ATTR, $GET_ATTR, $HAS_ATTR, $ATTR_TRUE, $MAYBE_CALL );    # Predeclared private subs
{
  my $DEFAULTS = {
    first_interval   => sub { 0 },
    refresh_interval => sub { 60 },
    initial_request  => sub { $_[0]->_uri_to_get( $_[0]->uri ) },
    timer            => sub {
      my ($self) = @_;
      require IO::Async::Timer::Periodic;
      my $timer = $self->$SET_ATTR(
        'timer' => IO::Async::Timer::Periodic->new(
          interval       => $self->refresh_interval,
          first_interval => $self->first_interval,
          on_tick        => sub { $self->_on_tick(@_) },
        ),
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
    return unless exists $_[0]->{ __PACKAGE__ . q[/] . $_[1] };
    return !!$_[0]->{ __PACKAGE__ . q[/] . $_[1] };
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

my $CLASS_PARAMS = [
  qw( on_updated_chunk on_updated on_error
    on_no_content refresh_interval first_interval
    http uri request )
];

my $MESSAGES = {
  'no_http'    => 'Attribute `http` is required, and should be a NAHTTP client',
  'no_request' => 'Either attribute `uri` ( A HTTP URI ) or `request` ( an HTTP::Request ) is required',
};

sub configure {
  my ( $self, %params ) = @_;

  exists $params{$_} and $self->$SET_ATTR( $_, delete $params{$_} ) for @{$CLASS_PARAMS};

  $self->$HAS_ATTR('http') or die $MESSAGES{no_http};

  $self->$HAS_ATTR('uri') or $self->$HAS_ATTR('request') or die $MESSAGES{no_request};

  return $self->SUPER::configure(%params);
}

sub start {
  my ($self) = @_;
  log_trace { "starting timer $self" };
  $self->timer->start;
}

sub on_updated_chunk { $_[0]->$MAYBE_CALL( 'on_updated_chunk', @_[ 1 .. $#_ ] ) }

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

sub on_updated {
  log_trace { 'on_updated' };
  $_[0]->$MAYBE_CALL( 'on_updated', @_[ 1 .. $#_ ] );
}

sub on_no_content {
  log_trace { 'on_no_content' };
  $_[0]->$MAYBE_CALL( 'on_no_content', @_[ 1 .. $#_ ] );
}

sub on_response {
  my ( $self, $response ) = @_;
  log_trace { 'on_response' };

  $response->is_success and return $self->on_updated($response);

  '304' eq $response->code and return $self->on_no_content($response);
}

sub on_error {
  log_trace { 'on_error' };
  $_[0]->$MAYBE_CALL( 'on_error', @_[ 1 .. $#_ ] );
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

  my $req  = $self->$GET_ATTR('last_request')->clone;
  my $resp = $self->$GET_ATTR('last_response');

  return $req if $resp->code =~ / \A [34]0\d \z/sx;

  if ( my $date = $resp->header('date') ) {
    $req->header( 'if-modified-since', $date );
  }
  return $req;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Net::Async::HTTP::Monitor - Stalk a HTTP URI efficiently and invoke code when it changes

=head1 VERSION

version 0.001000

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

=head1 AUTHOR

Kent Fredric <kentnl@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2015 by Kent Fredric <kentfredric@gmail.com>.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
