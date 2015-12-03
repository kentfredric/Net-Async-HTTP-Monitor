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

# This this sort of crap you have to pull when you don't have a MOP
# and can't subclass with Moo/C:Tiny. Also, these would be really nice as macros :(
__PACKAGE__->_add_accessor( http             => predicate => 1 );
__PACKAGE__->_add_accessor( uri              => predicate => 1 );
__PACKAGE__->_add_accessor( refresh_interval => default   => sub { 60 } );

__PACKAGE__->_add_sub_proxy('on_updated_chunk');
__PACKAGE__->_add_sub_proxy('on_updated');
__PACKAGE__->_add_sub_proxy('on_no_content');
__PACKAGE__->_add_sub_proxy('on_error');

__PACKAGE__->_add_accessor( first_interval => default => sub { 0 } );

__PACKAGE__->_add_accessor(
  initial_request => (
    default   => sub { $_[0]->_uri_to_get( $_[0]->uri ) },
    predicate => 1,
  ),
);
__PACKAGE__->_add_accessor(
  timer => default => sub {
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
__PACKAGE__->_add_accessor( _active        => init_arg => undef, setter => 1 );
__PACKAGE__->_add_accessor( _last_request  => init_arg => undef, setter => 1, predicate => 1 );
__PACKAGE__->_add_accessor( _last_response => init_arg => undef, setter => 1, predicate => 1 );

sub configure {
  my ( $self, %params ) = @_;

  __PACKAGE__->_swallow_constructor_args( $self, \%params );

  die 'Attribute `http` is required, and should be a NAHTTP client'
    unless $self->has_http;

  die 'Either attribute `uri` ( A HTTP URI ) or `request` ( an HTTP::Request ) is required'
    unless $self->has_uri or $self->has_initial_request;

  return $self->SUPER::configure(%params);
}

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

our %ARGS;

sub _swallow_constructor_args {
  my ( $class, $instance, $arghash ) = @_;
  my $argmap = $ARGS{$class};
  exists $arghash->{$_} and $instance->{ $argmap->{$_} } = delete $arghash->{$_} for keys %{$argmap};
}

sub _set_sub {
  my ( $class, $name, $code ) = @_;
  no strict 'refs';    ## no critic
  *{ $class . q[::] . $name } = $code;
}

sub _add_accessor {
  my ( $class, $name, %spec ) = @_;

  $class->_add_setter($name) if $spec{setter};

  $class->_add_predicate($name) if $spec{predicate};

  $spec{init_arg} = $name if not exists $spec{init_arg};

  $ARGS{$class}{ $spec{init_arg} } = $class . q[/] . $name if defined $spec{init_arg};

  if ( $spec{default} ) {
    return $class->_set_sub(
      $name => sub {
        exists $_[0]->{ $class . q[/] . $name } and return $_[0]->{ $class . q[/] . $name };
        $_[0]->{ $class . q[/] . $name } = $spec{default}->( $_[0] );
      },
    );
  }

  return $class->_set_sub( $name => sub { exists $_[0]->{ $class . q[/] . $name } and return $_[0]->{ $class . q[/] . $name } } );
}

sub _add_setter {
  my ( $class, $name, %spec ) = @_;
  my $subname;
  if ( $name =~ /^_/ ) {
    $subname = "_set${name}";
  }
  else {
    $subname = "set_${name}";
  }
  my $iname = $spec{iname} || $name;

  return $class->_set_sub( $subname, sub { $_[0]->{ $class . q[/] . $iname } = $_[1] } );
}

sub _add_predicate {
  my ( $class, $name, %spec ) = @_;
  my $subname;
  if ( $name =~ /^_/ ) {
    $subname = "_has${name}";
  }
  else {
    $subname = "has_${name}";
  }
  return $class->_set_sub( $subname, sub { exists $_[0]->{ $class . q[/] . $name } } );
}

sub _add_sub_proxy {
  my ( $class, $name, $code ) = @_;
  $ARGS{$class}{$name} = $class . q[/] . $name;
  return $class->_set_sub(
    $name => sub {
      log_trace { $name };
      exists $_[0]->{ $class . q[/] . $name } and return $_[0]->{ $class . q[/] . $name }->( @_[ 1 .. $#_ ] );
    }
  );
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
  $self->_set_active(1);
  $self->_set_last_request($request);
  $self->http->do_request(
    request   => $request,
    on_header => sub {
      $self->_set_last_response( $_[0] );
      $self->on_header(@_);
    },
    on_response => sub {
      $self->_set_active(0);
      $self->on_response(@_);
    },
    on_error => sub {
      $self->_set_active(0);
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

## Please see file perltidy.ERR

=head1 AUTHOR

Kent Fredric <kentnl@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2015 by Kent Fredric <kentfredric@gmail.com>.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
