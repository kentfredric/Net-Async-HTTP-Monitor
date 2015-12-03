use strict;
use warnings;

# ABSTRACT: Watch the MetaCPAN RSS feed for changes
use Cwd qw( realpath );
use lib realpath( [ caller(0) ]->[1] . "/../../lib" );
use Net::Async::HTTP::Monitor;

use IO::Async::Loop;
use Net::Async::HTTP;
use URI;

my $loop = IO::Async::Loop->new();
my $ua   = Net::Async::HTTP->new();

$loop->add($ua);

use Data::Dump qw(pp);
my $monitor = Net::Async::HTTP::Monitor->new(
  http             => $ua,
  refresh_interval => 10,
  uri              => URI->new('https://metacpan.org/feed/recent'),
  on_updated       => sub {
    my ($response) = @_;
    *STDERR->print( "Full Response: \n" . ( length $response->content ) . "\n" );
  },
  on_updated_chunk => sub {
    my ( $response, @chunk ) = @_;
    *STDERR->print( "Got new content!: " . substr( ( join q[], @chunk ), 0, 10 ) . "\n" );
  },
  on_no_content => sub {
    *STDERR->print("No content check!\n");
  },
  on_error => sub {
    *STDERR->print( "Got error!\n" . join q[], pp(@_) );
  },
);
$monitor->start;
$loop->add($monitor);

$loop->run;

