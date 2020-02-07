#!/usr/bin/perl -w
#
# hls-fetch - Download and decrypt HTTP Live Streaming videos.
# Copyright (C) 2012 Oskar Liljeblad
# Copyright (C) 2020 [anp/hsw] sysop@880.ru
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

# uncomment for standalone use (testing):
# open(my $fh, '>', "output.ts") or die "open failed' $!";
# worker_start($fh,"http://examplehlsserver.com/stream.m3u8");

use strict;
use HTML::Parser;
use LWP::UserAgent;
use File::Temp qw(tempfile);
use URI::URL;
use constant READ_SIZE => 1024;

use IO::Handle;

my $output_file = shift;
my $hlsurl = shift;

my $browser = LWP::UserAgent->new;

sub worker_start {
 my %opt = ('bandwidth' => 'max');

 my $video_fh = shift;
 my $url = shift;

 binmode $video_fh;

 $browser->cookie_jar({});

 my $sequence_last = 0;
 loop:

 my $data = eval { fetch_url($url) }; die "$url: cannot fetch playlist: $@" if $@;
 my @lines = split(/\r*\n|\r\n*/, $data);
 die "$url: invalid playlist, no header\n" if @lines < 1 || $lines[0] ne '#EXTM3U';

 if (!grep { /^#EXTINF:/ } @lines) {
  my (@streams, $last_stream);
  foreach my $line (@lines) {
    if ($line =~ /^#EXT-X-STREAM-INF:(.*)$/) {
      $last_stream = { parse_m3u_attribs($url, $1) };
      push @streams, $last_stream;
    } elsif ($line !~ /^#EXT/) {
      die "$url: missing #EXT-X-STREAM-INF for URL: $line\n" if !defined $last_stream;
      $last_stream->{'URL'} = $line;
      $last_stream = undef;
    }
  }
  die "$url: no streams found in playlist\n" if !@streams;

  warn "$url: non-numeric bandwidth in playlist\n" if grep { $_->{'BANDWIDTH'} =~ /\D/ } @streams;
  my @bandwidths = sort { $a <=> $b } grep { /^\d+$/ } map { $_->{'BANDWIDTH'} } @streams;
  print STDERR "Bandwidths: ", join(', ', @bandwidths), "\n" if $opt{'verbose'};
  my $stream;
  if ($opt{'bandwidth'} eq 'min') {
    ($stream) = grep { $_->{'BANDWIDTH'} == $bandwidths[0] } @streams;
  } elsif ($opt{'bandwidth'} eq 'max') {
    ($stream) = grep { $_->{'BANDWIDTH'} == $bandwidths[-1] } @streams;
  } else {
    ($stream) = grep { $opt{'bandwidth'} == $_->{'BANDWIDTH'} } @streams;
    die "$url: no streams with bandwidth $opt{'bandwidth'} in playlist\n" if !defined $stream;
  }
  print STDERR "Bandwidth (selected): $stream->{'BANDWIDTH'}\n" if $opt{'verbose'};
  $url = url($stream->{'URL'}, $url)->abs()->as_string();
  print STDERR "URL (index): $url\n" if $opt{'verbose'};

  $data = eval { fetch_url($url) }; die "$url: cannot fetch playlist: $@" if $@;
  @lines = split(/\r?\n/, $data);
  die "$url: invalid playlist, no header\n" if @lines < 1 || $lines[0] ne '#EXTM3U';
 }

 my $sequence = 0;
 my $duration = 0;
 my $duration_default = 0;
 my $errorcounter = 0;

 my (%segments, $cryptkey_url);
 foreach my $line (@lines) {
  if ($line =~ /^#EXT-X-MEDIA-SEQUENCE:(\d+)$/) {
    $sequence = int($1);
    print STDERR "First sequence number: $sequence\n" if $opt{'verbose'};
  }  elsif ($line =~ /^#EXT-X-TARGETDURATION:(\d+)/) {
    $duration = int($1);
    print STDERR "Default duration: $duration_default\n" if $opt{'verbose'};
  }  elsif ($line =~ /^#EXTINF:(\d+)/) {
    $duration = int($1);
    print STDERR "Target duration: $duration\n" if $opt{'verbose'};
  } elsif ($line =~ /^#EXT-X-KEY:(.*)$/) {
    my %attr = parse_m3u_attribs($url, $1);
    if (exists $attr{'METHOD'} && $attr{'METHOD'} ne 'AES-128') {
	warn "$url: unsupported encryption method $attr{'METHOD'} in playlist\n";
	goto loop_sleep;
    }
    $cryptkey_url = $attr{'URI'};
    if (!defined $cryptkey_url) {
	warn "$url: missing encryption key URI in playlist\n";
	goto loop_sleep;
    }
  } elsif ($line !~ /^#EXT/) {
    $segments{$sequence} = { 'url' => $line, 'cryptkey_url' => $cryptkey_url };
    $sequence++;
  }
 }
 if (!scalar keys %segments) {
    print STDERR "$url: no segments in playlist\n" ;
    goto loop_sleep;
 }

 my %cryptkeys;
 print STDERR "Segments: ", scalar keys %segments, "\n" if $opt{'verbose'};

 $| = 1;
 foreach my $sequence (sort { $a <=> $b } keys %segments) {
  if ($sequence <= $sequence_last) {
	print STDERR "Seen $sequence\n" if $opt{'verbose'};
	if ($sequence + 1000 < $sequence_last) {
	    print STDERR "Counter possibly wrapped, reset sequence.\n" if $opt{'verbose'};
	    $sequence_last = 0;
	} else {
	    next;
	}
  }
  my $segment = $segments{$sequence};
  my $segment_url = url($segment->{'url'}, $url)->abs()->as_string();
  print STDERR "URL (segment $sequence): $segment_url\n" if $opt{'verbose'};
  printf STDERR "\r%d/%d\n", $sequence, scalar keys %segments if !$opt{'quiet'} && !$opt{'verbose'};

#  if (!$opt{'no-decrypt'} && defined $segment->{'cryptkey_url'} && !exists $cryptkeys{$segment->{'cryptkey_url'}}) {
#    print STDERR "URL (key): ", $segment->{'cryptkey_url'}, "\n" if $opt{'verbose'};
#    my $cryptkey = eval { fetch_url($segment->{'cryptkey_url'}) };
#    die "$segment->{'cryptkey_url'}: cannot fetch encryption key: $@" if $@;
#    $cryptkey = join('', map { sprintf('%02x', ord) } split(//, $cryptkey));
#    print STDERR "Key: $cryptkey\n" if $opt{'verbose'};
#    $cryptkeys{$segment->{'cryptkey_url'}} = $cryptkey;
#  }

#  my ($segment_fh, $segment_file) = tempfile();
#  close $segment_fh;
#  eval {
    fetch_segment:
	if (!defined syswrite($video_fh, fetch_url($segment_url, $duration))) {
	    last if $errorcounter > 3;
	    $errorcounter++;
	    sleep 1;
	    goto fetch_segment;
	};

#    eval { fetch_url($segment_url, $duration, $segment_file) };
#    if ( $@ ) {
#	print STDERR "$segment_url: cannot not fetch segment: $@" ;
#	sleep 1;
#	# break loop!
#	goto fetch_segment;
#    }

#    if (!$opt{'no-decrypt'} && defined $segment->{'cryptkey_url'}) {
#      my ($decrypt_fh, $decrypt_file) = tempfile();
#      close $decrypt_fh;
#      my $iv = sprintf('%032x', $sequence);
#      my @cmd = ('openssl', 'aes-128-cbc', '-d', '-in', $segment_file, '-out', $decrypt_file, '-K', $cryptkeys{$segment->{'cryptkey_url'}}, '-iv', $iv);
#      system @cmd;
#      unlink $segment_file || warn "$segment_file: cannot remove file: $!\n";
#      $segment_file = $decrypt_file;
#
#      if ($? != 0) {
#	print STDERR "$segment_file: openssl failed (status $?)\n";
#	goto loop;
#      }
#    }
#    open ($segment_fh, '<', $segment_file) || die "$segment_file: cannot open file: $!\n";

#    for (;;) {
#      my $size = sysread($segment_fh, $data, READ_SIZE);
#      last if !defined $size;
#      last if $size == 0;
#      last if !defined syswrite($video_fh, $data);
#    }
#    close $segment_fh;
#  };
#  unlink $segment_file || warn "$segment_file: cannot remove file: $!\n";
#  die $@ if $@;
  $sequence_last = $sequence;
 }

 loop_sleep:
 print STDERR "List finished, sleeping for ", $duration, " sec\n";
 sleep $duration;
 goto loop;
}

sub parse_m3u_attribs {
  my ($url, $attr_str) = @_;
  my %attr;
  for (my $as = $attr_str; $as ne ''; ) {
    $as =~ s/^?([^=]*)=([^,"]*|"[^"]*")\s*(,\s*|$)// or die "$url: invalid attributes in playlist: $attr_str\n";
    my ($key, $val) = ($1, $2);
    $val =~ s/^"(.*)"$/$1/;
    $attr{$key} = $val;
  }
  return %attr;
}

sub fetch_url {
  my ($url, $connect_timeout, $filename) = @_;
  if (defined $connect_timeout) {
    $connect_timeout = 1;
  }
  $browser->timeout($connect_timeout);
    my $response = $browser->get($url);
    print STDERR "URL:", $url, $response->status_line(), "\n" if !$response->is_success;
    return $response->decoded_content();
}

$SIG{'PIPE'} = sub {
    die "PIPE Closed!\n";
};
