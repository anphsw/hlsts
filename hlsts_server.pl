#!/usr/bin/perl
use warnings;
use strict;


use strict;
use warnings;

use Socket;
use IO::Select;

use threads;
use threads::shared;

$|  = 1;

# get args
my $port_listen = shift;
my $hlsurl = shift;

require "hlsts_worker.pl";

local *S;

socket     (S, PF_INET   , SOCK_STREAM , getprotobyname('tcp')) or die "couldn't open socket: $!";
setsockopt (S, SOL_SOCKET, SO_REUSEADDR, 1);
bind       (S, sockaddr_in($port_listen, INADDR_ANY));
listen     (S, 5)                                               or die "don't hear anything:  $!";

my $ss = IO::Select->new();
$ss -> add (*S);

while(1) {
  my @connections_pending = $ss->can_read();
  foreach (@connections_pending) {
    my $fh;
    my $remote = accept($fh, $_);

    my($port,$iaddr) = sockaddr_in($remote);
    my $peeraddress = inet_ntoa($iaddr);

    my $t = threads->create(\&new_connection, $fh);
    $t->detach();
  }
}

sub extract_vars {
  my $line = shift;
  my %vars;

  foreach my $part (split '&', $line) {
    $part =~ /^(.*)=(.*)$/;

    my $n = $1;
    my $v = $2;
  
    $n =~ s/%(..)/chr(hex($1))/eg;
    $v =~ s/%(..)/chr(hex($1))/eg;
    $vars{$n}=$v;
  }

  return \%vars;
}

sub new_connection {
  print STDERR "Connection opened.\n";
  my $fh = shift;

  binmode $fh;

  my %req;

  $req{HEADER}={}; 

  my $request_line = <$fh>;
  my $first_line = "";

  while ($request_line ne "\r\n") {
     unless ($request_line) {
       close $fh; 
     }

     chomp $request_line;

     unless ($first_line) {
       $first_line = $request_line;

      my @parts = split(" ", $first_line);
       if (@parts != 3) {
         close $fh;
       }

       $req{METHOD} = $parts[0];
       $req{OBJECT} = $parts[1];
     }
     else {
       my ($name, $value) = split(": ", $request_line);
       $name       = lc $name;
       $req{HEADER}{$name} = $value;
     }

     $request_line = <$fh>;
  }

  http_request_handler($fh, \%req);

  close $fh;
  print STDERR "Connection closed.\n";
}

sub http_request_handler {
  my $fh     =   shift;
  my $req_   =   shift;

  my %req    =   %$req_;

  syswrite($fh, "HTTP/1.0 200 OK\r\n");
  syswrite($fh, "Server: adp perl webserver\r\n");
  syswrite($fh, "\r\n");

  worker_start($fh,$hlsurl);

  print STDERR "Worker finished (which should never happen).\n";
}
