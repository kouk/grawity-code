#!/usr/bin/perl
# r20091107
use strict;
#use brain;
use IO::Socket;

my ($bus, $notify, $dobject);
eval {
	require Net::DBus;
	$bus = Net::DBus->session;
	$notify = $bus->get_service("org.freedesktop.Notifications");
	$dobject = $notify->get_object("/org/freedesktop/Notifications",
		"org.freedesktop.Notifications");
};

sub xml_escape($) {
	my ($_) = @_;
	s/&/\&amp;/g;
	s/</\&lt;/g;
	s/>/\&gt;/g;
	s/"/\&quot;/g;
	return $_;
}

if (defined $bus) {
	print "Net::DBus available\n";
}
else {
	print "Net::DBus not available, falling back to notify-send\n";
}

my $ListenPort = shift @ARGV or 22754;

my $socket = IO::Socket::INET->new(
	Proto => 'udp',
	LocalPort => $ListenPort,
	Reuse => 1,
) or die "socket error: $!";

my ($message, $title, $text);

print "Waiting for notifications on :$ListenPort\n";

while ($socket->recv($message, 1024)) {
	my ($port, $host) = sockaddr_in($socket->peername);
	$host = join '.', unpack "C*", $host;

	chomp $message;
	my ($source, $icon, $title, $text) = split / \| /, $message, 4;

	print "from: $host:$port\n";
	print "app: $source\n";
	
	if ($title eq "") { next; }
	if ($source eq "") { $source = "unknown"; }
	
	print "title: $title\n";
	print "text: $text\n";

	$text = xml_escape($text);

	if (defined $dobject) {
		$dobject->Notify($source, 0, $icon, $title, $text, [], {}, 3000);
	}
	else {
		my @args = ("notify-send");
		push @args, "--icon=$icon" unless $icon eq "";
		push @args, "--category=$source" unless $source eq "";
		push @args, $title;
		push @args, $text unless $text eq "";
		system @args;
	}

}
die "recv error: $!";
