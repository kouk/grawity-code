#!/usr/bin/env perl
use strict;
use constant LDAP_HOST => "ldap.cluenet.org";

use Getopt::Long;
use Socket;
use Net::DNS;
use Net::IP;
use Authen::SASL;
use Socket::GetAddrInfo qw(:newapi getaddrinfo);
use Net::LDAP;
use Net::LDAP::Extension::WhoAmI;
use Net::LDAP::Util qw(ldap_explode_dn);
use Data::Dumper;
use Text::Format;

my $ldap;
my $cmd;
my $exit;
my $my_name;
my %commands;

use constant SHELL_SERVICES => qw(atd cron login passwd sshd su sudo);

### String and hostname manipulation

# Canonicalize a hostname
sub canon_host {
	my ($host) = @_;
	my %hint = (flags => Socket::GetAddrInfo->AI_CANONNAME);
	my ($err, @ai) = getaddrinfo($host, "", \%hint);
	return $err ? $host : ((shift @ai)->{canonname} // $host);
}

sub lookup_host {
	my ($host) = @_;
	my @addrs = ();
	my $r = Net::DNS::Resolver->new;

	my $query = $r->query($host, "A");
	if ($query) { push @addrs, $_->address for $query->answer }

	$query = $r->query($host, "AAAA");
	if ($query) { push @addrs, $_->address for $query->answer }

	return @addrs;
}

sub format_name {
	my ($user) = @_;
	my $name = $user->{uid};
	if ($user->{cn} ne $user->{uid}) {
		$name .= " (".$user->{cn}.")";
	}
	return $name;
}

sub format_address {
	my ($host, $port) = @_;
	if ($host =~ /:/) {
		$host = Net::IP::ip_compress_address($host, 6);
		return "[$host]:$port";
	} else {
		return "$host:$port";
	}
}


# FQDNize a given host
sub fqdn {
	my ($host) = @_;
	return ($host =~ /\./) ? $host : "$host.cluenet.org";
}

# Split "host/service" arg
sub to_hostservice {
	my ($host, $service, $rest) = split /\//, shift, 3;
	return (fqdn($host), $service, $rest);
}
sub to_hostservice_safe {
	my ($host, $service, $rest) = split /\//, shift, 3;
	unless ($host and $service) {
		die "syntax error: empty host or service: '$host/$service'\n";
	}
	return (fqdn($host), $service, $rest);
}

#
sub user_dn {"uid=".shift().",ou=people,dc=cluenet,dc=org"}
sub server_dn {"cn=".fqdn(shift).",ou=servers,dc=cluenet,dc=org"}

# Find the next rightmost RDN after given base
sub from_dn {
	my ($entrydn, $branchdn, $nonames) = @_;
	my %opts = (reverse => 1, casefold => "lower");
	my @entry = @{ldap_explode_dn($entrydn, %opts)};
	my @base = @{ldap_explode_dn($branchdn, %opts)};
	for my $rdn (@base) {
		my @brdn = %$rdn;
		my @erdn = %{shift @entry};
		return if ($erdn[0] ne $brdn[0]) or ($erdn[1] ne $brdn[1]);
	}
	my @final = %{shift @entry};
	return $nonames ? $final[1] : @final;
}
sub user_from_dn {
	from_dn(shift, "ou=people,dc=cluenet,dc=org", 1);
}
sub server_from_dn {
	from_dn(shift, "ou=servers,dc=cluenet,dc=org", 1);
}

# Output fields

my $_rows = 0;
sub row { $_rows++; printf "%-16s%s\n", @_; }
sub endsection { if ($_rows) {print "\n"; $_rows = 0;} }

### LDAP connection

# Establish LDAP connection, authenticated or anonymous
sub connect_auth {
	my $sasl = Authen::SASL->new("GSSAPI");
	my $ldap = Net::LDAP->new(LDAP_HOST) or die "$!";
	#$ldap->start_tls(verify => "require",
	#	cafile => "$ENV{HOME}/lib/ca/cluenet.pem") or die "$@";
	my $authen = $sasl->client_new("ldap", canon_host LDAP_HOST);
	my $msg = $ldap->bind(sasl => $authen);
	$msg->code and die "error: ".$sasl->error;
	return $ldap;
}
sub connect_anon {
	my $ldap = Net::LDAP->new(LDAP_HOST) or die "$!";
	$ldap->bind;
	return $ldap;
}

# Get and cache LDAP authzid
sub whoami {
	if (!defined $my_name) {
		$my_name = $ldap->who_am_i->response;
		$my_name =~ s/^u://;
		$my_name =~ s/^dn:uid=(.+?),.*$/\1/;
		# cross-realm
		$my_name =~ s/\@nullroute\.eu\.org$//;
	}
	return $my_name;
}

sub ldap_errmsg {
	my ($msg, $dn) = @_;
	my $text = "LDAP error: ".$msg->error."\n";
	if ($dn) {
		$text .= "\tfailed: $dn\n";
	}
	if ($msg->dn) {
		$text .= "\tmatched: ".$msg->dn."\n";
	}
	$text;
}

# Call `ldapsearch` to dump raw LDIF
sub ext_dump_ldif {
	my (%args) = @_;
	my @cmd = ("ldapsearch", "-ZZQLLL");
	push @cmd, "-s", $args{scope}		if $args{scope};
	push @cmd, "-b", $args{base}		if $args{base};
	push @cmd, $args{filter}		if $args{filter};
	push @cmd, @{$args{attributes}}		if $args{attributes};
	system(@cmd);
}

sub get_server_info {
	my ($host, $is_dn) = @_;
	my $dn = $is_dn ? $host : server_dn($host);

	my $res = $ldap->search(base => $dn, scope => "base",
		filter => q(objectClass=server));
	$res->is_error and die ldap_errmsg($res, $dn);
	for my $entry ($res->entries) {
		my %server = map {$_ => [$entry->get_value($_)]} $entry->attributes;
		for (qw(cn owner internalAddress sshPort)) {
			$server{$_} = $server{$_}->[0];
		}
		for (qw(isActive isOfficial userAccessible)) {
			$server{$_} = $server{$_}->[0] eq "TRUE";
		}
		$server{address} = [lookup_host($server{cn})];
		return \%server;
	}
}

sub print_server_info {
	my ($server, $owner, @admins) = @_;
	@admins = sort {$a->{uid} cmp $b->{uid}} @admins;
	my $port = $server->{sshPort} // 22;

	row "HOSTNAME:"		=> uc $server->{cn};
	row "address:"		=> format_address($_, $port)
		for @{$server->{address}};
	row "owner:"		=> format_name($owner);
	row "admin:"		=> format_name($_)
		for @admins;
	row "status:"		=> join(", ", grep {defined} (
					$server->{isOfficial}     ? "official" : "unofficial",
					$server->{userAccessible} ? "public"   : "private",
					$server->{isActive}       ? "active"   : "inactive",
					(grep {/:/} @{$server->{address}}) ? "IPv6" : undef,
				));
	if (defined $server->{authorizedService}) {
		my @services = sort @{$server->{authorizedService}};
		row "services:"	=> join(", ", @services);
	}
	endsection;

	my $fmt = Text::Format->new(leftMargin => 4, firstIndent => 0);

	if ($server->{description}) {
		print $fmt->format(@{$server->{description}}), "\n";
	}

	if ($server->{serverRules}) {
		if ($server->{serverRules}[0] eq 'default') {
			$server->{serverRules} = ["Don't break shit.",
				"(To do: fix default serverRules)"];
		}
		print $fmt->format(@{$server->{serverRules}}), "\n";
	}
}

sub get_user_info {
	my ($user, $is_dn) = @_;
	my $dn = $is_dn ? $user : user_dn($user);

	my $res = $ldap->search(base => $dn, scope => "base",
		filter => q(objectClass=posixAccount));
	$res->is_error and die ldap_errmsg($res, $dn);
	for my $entry ($res->entries) {
		my %user = map {$_ => [$entry->get_value($_)]} $entry->attributes;
		for (qw(uid uidNumber gidNumber gecos homeDirectory loginShell cn
				krb5PrincipalName clueIrcNick ircServicesUser)) {
			$user{$_} = $user{$_}->[0];
		}
		$user{cn} =~ s/^\s+|\s+$//g;
		if (defined $user{altEmail}) {
			print Dumper($user{altEmail});
			push @{$user{mail}}, @{$user{altEmail}};
		}
		return \%user;
	}
}

sub print_user_info {
	my ($user) = @_;
	row "PERSON:"		=> format_name($user);
	row "uid:"		=> $user->{uidNumber};
	row "shell:"		=> $user->{loginShell} // "(unset)";
	row "IRC account:"	=> $user->{ircServicesUser}		if $user->{ircServicesUser};
	row "email:"		=> join(", ", @{$user->{mail}})		if $user->{mail};
	endsection;
}

### Miscellaneous

sub usage {
	my ($cmd, @args) = @_;
	my $text = $cmd." ".join(" ", map {$_ eq '...' ? $_ : "<$_>"} @args);

	print STDERR "Usage: $text\n";
	exit 2;
}

### User interface commands

$commands{"access"} = sub {
	my (@services, @add_users, @del_users);
	for (@_) {
		if (/\//) {
			my ($h, $s) = to_hostservice_safe($_);
			if ($s eq 'shell') {
				push @services, [$h, $_] for SHELL_SERVICES;
			} else {
				push @services, [$h, $s];
			}
		}
		elsif (/^\+(.+)$/) {push @add_users, $1}
		elsif (/^-(.+)$/) {push @del_users, $1}
		else {die "syntax error: '$_'\n"}
	}

	usage("access", qw(host/service ... [+-]user ...))
		unless @services;

	if (@add_users or @del_users) {
		$ldap = connect_auth;
	} else {
		$ldap = connect_anon;
	}

	for (@services) {
		my ($host, $service) = @$_;
		my $group = "cn=$service,cn=svcAccess,".server_dn($host);

		if (@add_users or @del_users) {
			# found +user/-user in args -- update members
			my (@users, @add_users_svc, @del_users_svc, %changes);

			# Avoid errors on duplicates.
			my $res = $ldap->search(base => $group, scope => "base",
				filter => q(objectClass=*), attrs => ["member"]);
			$res->is_error and warn ldap_errmsg($res, $group);
			for my $entry ($res->entries) {
				@users = map {user_from_dn $_} $entry->get_value("member");
			}
			@add_users_svc = grep {not $_ ~~ @users} @add_users;
			@del_users_svc = grep {$_ ~~ @users} @del_users;

			if (@add_users_svc) {
				$changes{add} = {member => [map {user_dn $_} @add_users_svc]};
				print "$host/$service: Adding: ".join(", ", @add_users_svc)."\n";
			}
			if (@del_users_svc) {
				$changes{delete} = {member => [map {user_dn $_} @del_users_svc]};
				print "$host/$service: Removing: ".join(", ", @del_users_svc)."\n";
			}

			if (@add_users_svc or @del_users_svc) {
				my $res = $ldap->modify($group, %changes);
				$res->is_error and warn ldap_errmsg($res, $group);
			} else {
				print "$host/$service: Nothing to do\n";
			}
		}
		else {
			# list members
			my $res = $ldap->search(base => $group, scope => "base",
				filter => q(objectClass=*), attrs => ["member"]);
			$res->is_error and warn ldap_errmsg($res, $group);
			for my $entry ($res->entries) {
				my @members = $entry->get_value("member");
				print "$host/$service\t$_\n"
					for sort map {user_from_dn $_} @members;
			}
		}
	}
};

$commands{"acl"} = sub {
	my $err;
	usage("acl", qw(host ...)) unless @_;
	$ldap = connect_anon;
	for my $host (@_) {
		my ($dn, $res);
		# authz = authorizedService attributes
		# acl = cn=svcAccess subentry
		my (%services, @svcs_authz, @svcs_acl);

		$dn = server_dn($host);
		$res = $ldap->search(base => $dn, scope => "base",
			filter => q(objectClass=*), attrs => ["authorizedService"]);
		if ($res->is_error) { warn ldap_errmsg($res, $dn); $err++; }
		for my $entry ($res->entries) {
			@svcs_authz = $entry->get_value("authorizedService");
			last;
		}

		$dn = "cn=svcAccess,".server_dn($host);
		$res = $ldap->search(base => $dn, scope => "one",
			filter => q(objectClass=groupOfNames), attrs => ["cn"]);
		if ($res->is_error) { warn ldap_errmsg($res, $dn); $err++; }
		for my $entry ($res->entries) {
			push @svcs_acl, $entry->get_value("cn");
		}

		# create a hash of $service => [has_authz, has_acl]
		%services = map {$_ => [1, undef]} @svcs_authz;
		$services{$_}->[1] = 1 for @svcs_acl;

		for my $svc (sort keys %services) {
			my ($authz, $acl) = @{$services{$svc}};
			if (!$authz) {
				print STDERR "warning: service '$svc' does not have an authorizedService\n";
			} elsif (!$acl) {
				print STDERR "warning: service '$svc' does not have an ACL\n";
			}
			print "$host/$svc\n";
		}
	}
};

$commands{"acl:create"} = sub {
	my $err;
	usage("acl:create", qw(host/service ...)) unless @_;
	$ldap = connect_auth;
	for (@_) {
		my ($host, $service) = to_hostservice_safe($_);
		my ($dn, $res, %entry);

		print "Creating ACL: $host/$service\n";
		$dn = "cn=$service,cn=svcAccess,".server_dn($host);
		%entry = (
			objectClass => "groupOfNames",
			cn => $service,
			member => user_dn(whoami),
		);
		$res = $ldap->add($dn, attr => [%entry]);
		if ($res->is_error) { warn ldap_errmsg($res, $dn); $err++; }

		$dn = server_dn($host);
		%entry = (authorizedService => $service);
		$res = $ldap->modify($dn, add => \%entry);
		if ($res->is_error) { warn ldap_errmsg($res, $dn); $err++; }
	}
	return $err;
};

$commands{"acl:delete"} = sub {
	my $err;
	usage("acl:delete", qw(host/service ...)) unless @_;
	$ldap = connect_auth;
	for (@_) {
		my ($host, $service) = to_hostservice_safe($_);
		my ($dn, $res, %entry);

		print "Deleting ACL: $host/$service\n";
		$dn = "cn=$service,cn=svcAccess,".server_dn($host);
		$res = $ldap->delete($dn);
		if ($res->is_error) { warn ldap_errmsg($res, $dn); $err++; }

		$dn = server_dn($host);
		%entry = (authorizedService => $service);
		$res = $ldap->modify($dn, delete => \%entry);
		if ($res->is_error) { warn ldap_errmsg($res, $dn); $err++; }
	}
	return $err;
};

$commands{"server"} = sub {
	$ldap = connect_anon;
	for (@_) {
		my $server = get_server_info($_);
		my $owner = get_user_info($server->{owner}, 1);
		my @admins = map {get_user_info($_, 1)}
			@{$server->{authorizedAdministrator}};
		print_server_info($server, $owner, @admins);
	}
	return 0;
};

$commands{"server:getdn"} = sub {
	print server_dn($_)."\n" for @_;
	return 0;
};

$commands{"server:dump"} = sub {
	ext_dump_ldif(base => server_dn($_), scope => "sub") for @_;
	return 0;
};

$commands{"server:list"} = sub {
	$ldap = connect_anon;
	my $base = "ou=servers,dc=cluenet,dc=org";
	my $res = $ldap->search(base => $base, scope => "one",
		filter => q(objectClass=server), attrs => ["cn"]);
	if ($res->is_error) { die ldap_errmsg($res, $base); }
	print "$_\n" for sort map {($_->get_value("cn"))[0]} $res->entries;
};

$commands{"server:admin"} = sub {
	my (@hosts, @add, @del);
	for (@_) {
		if (/^\+(.+)$/) {push @add, $1}
		elsif (/^-(.+)$/) {push @del, $1}
		else {push @hosts, $_}
	}

	usage("server:admin", qw(host [+-]user ...))
		unless @hosts;

	# TODO:
	#  "access" nests if/for
	#  this command nests for/if
	if (@add or @del) {
		# update admins
		$ldap = connect_auth;
		for my $host (@hosts) {
			my (@admins, $owner, @add_host, @del_host, %changes);
			my $sdn = server_dn($host);
			my $res = $ldap->search(base => $sdn, scope => "base",
				filter => q(objectClass=server),
				attrs => ["authorizedAdministrator", "owner"]);
			$res->is_error and warn ldap_errmsg($res, $sdn);
			for my $entry ($res->entries) {
				$owner = user_from_dn($entry->get_value("owner"));
				@admins = map {user_from_dn $_} $entry->get_value("authorizedAdministrator");
			}
			@add_host = grep {not $_ ~~ @admins} @add;
			@del_host = grep {$_ ~~ @admins} @del;

			if ($owner ~~ @add_host) {
				warn "$host: Will not add $owner (already is server owner)\n";
				@add = grep {$_ ne $owner} @add_host;
			}

			if (@add_host) {
				$changes{add} = {authorizedAdministrator => [map {user_dn $_} @add_host]};
				print "$host: Adding: ".join(", ", @add_host)."\n";
			}
			if (@del_host) {
				$changes{delete} = {authorizedAdministrator => [map {user_dn $_} @del_host]};
				print "$host: Removing: ".join(", ", @del_host)."\n";
			}

			if (@add_host or @del_host) {
				my $res = $ldap->modify($sdn, %changes);
				$res->is_error and warn ldap_errmsg($res, $sdn);
			} else {
				print "$host: Nothing to do\n";
			}
		}
	}
	else {
		# list admins
		$ldap = connect_anon;
		for my $host (@hosts) {
			my $sdn = server_dn($host);
			my $res = $ldap->search(base => $sdn, scope => "base",
				filter => q(objectClass=server),
				attrs => ["authorizedAdministrator", "owner"]);
			$res->is_error and warn ldap_errmsg($res, $sdn);
			for my $entry ($res->entries) {
				my @admins = sort map {user_from_dn $_}
					$entry->get_value("authorizedAdministrator");
				my $owner = user_from_dn $entry->get_value("owner");
				print "$host\t$owner\t(owner)\n";
				print "$host\t$_\n" for @admins;
			}
		}
	}
};

$commands{"server:create"} = sub {
	my $err;
	$ldap = connect_auth;
	usage("server:create", qw(hostname)) unless @_;

	my ($host, $dn, $subdn, $owner, $res, %entry);
	$host = shift;
	$dn = server_dn($host);

	Getopt::Long::GetOptionsFromArray(\@_, "o|owner=s" => \$owner);
	if (!defined $owner) {
		die "error: owner must be specified\n";
	}

	%entry = (
		objectClass => ["server", "ipHost",
			"authorizedServiceObject", "serviceRequirementObject"],
		cn => fqdn($host),
		owner => user_dn($owner),
		isOfficial => "FALSE",
		userAccessible => "TRUE",
		isActive => "TRUE",

		authorizedService => [SHELL_SERVICES],

		# dummy address for oC=ipHost
		ipHostNumber => "0.0.0.0",
	);
	print Dumper \%entry;
	$res = $ldap->add($dn, attr => [%entry]);
	if ($res->is_error) { die ldap_errmsg($res, $dn); $err++; }

	my $subdn = "cn=svcAccess,$dn";
	%entry = (
		objectClass => "groupOfGroups",
		cn => "svcAccess",
		description => "Tree for groups of users that can access certain services.",
	);
	print Dumper \%entry;
	$res = $ldap->add($subdn, attr => [%entry]);
	if ($res->is_error) { warn ldap_errmsg($res, $dn); $err++; }

	for (SHELL_SERVICES) {
		$subdn = "cn=$_,cn=svcAccess,$dn";
		%entry = (
			objectClass => "groupOfNames",
			cn => $_,
			member => user_dn($owner),
		);
		print Dumper \%entry;
		$res = $ldap->add($subdn, attr => [%entry]);
		if ($res->is_error) { warn ldap_errmsg($res, $dn); $err++; }
	}

	return $err;
};

$commands{"server:delete"} = sub {
	my $err;
	usage("server:delete", qw(service ...)) unless @_;
	$ldap = connect_auth;
	for (@_) {
		my ($host, $dn, $res, @children, $subdn, $num);
		$host = fqdn($_);
		$dn = server_dn($host);
		print "Deleting server: $host\n";

		# delete entire subtree
		$res = $ldap->search(base => $dn, scope => "sub",
			filter => q(objectClass=*), attributes => ["dn"]);
		@children = reverse map {$_->dn} $res->entries;
		$num = @children;
		for $subdn (@children) {
			$res = $ldap->delete($subdn);
			if ($res->is_error) { warn ldap_errmsg($res, $dn); $err++; $num--; }
		}
		print "... $num entries deleted\n";
	}

	return $err;
};

$commands{"user"} = sub {
	$ldap = connect_anon;
	for my $user (@_) {
		print_user_info(get_user_info($user));
	}
	return 0;
};

$commands{"user:getdn"} = sub {
	print user_dn($_)."\n" for @_;
	return 0;
};

$commands{"user:dump"} = sub {
	ext_dump_ldif(base => user_dn($_), scope => "sub") for @_;
	return 0;
};

$commands{"user:acs"} = sub {
	if (@_) {
		my %changes = ();
		for (@_) {
			my ($key, $value) = /^(.+)=(\w+)?$/
				or die "syntax error: $_\n";
			$value =~ /^(anon|user|none|default)?$/
				or die "error: valid values are: anon user none default\n";
			$key = "acs".$key;
			$changes{lc $key} = $value || "default";
		}

		my (%replace, @delete);
		for my $key (keys %changes) {
			if ($changes{$key} eq 'default') {
				print "Deleting $key\n";
				push @delete, $key;
			} else {
				print "Setting $key to '$changes{$key}'\n";
				$replace{$key} = $changes{$key};
			}
		}

		$ldap = connect_auth;
		my $dn = user_dn(whoami);
		my $res = $ldap->modify($dn, replace => \%replace,
			delete => \@delete);
		if ($res->is_error) { die ldap_errmsg($res, $dn); }
		return 0;
	}
	else {
		$ldap = connect_auth;
		my $dn = user_dn(whoami);
		my $res = $ldap->search(base => $dn, scope => "base",
			filter => q(objectClass=posixAccount));
		$res->is_error and die ldap_errmsg($res, $dn);
		for my $entry ($res->entries) {
			for my $attr (sort grep {/^acs/} $entry->attributes) {
				my $value = $entry->get_value($attr);
				$attr =~ s/^acs//;
				print "$attr: $value\n";
			}
		}
	}
};

$commands{"user:acs:compare"} = sub {
	my (@public_attrs, @private_attrs);

	$ldap = connect_auth;
	my $dn = user_dn(whoami);
	my $res = $ldap->search(base => $dn, scope => "base",
		filter => q(objectClass=posixAccount));
	$res->is_error and die ldap_errmsg($res, $dn);
	for my $entry ($res->entries) {
		@private_attrs = $entry->attributes;
	}

	$ldap->unbind;
	$ldap = connect_anon;
	$res = $ldap->search(base => $dn, scope => "base",
		filter => q(objectClass=posixAccount));
	$res->is_error and die ldap_errmsg($res, $dn);
	for my $entry ($res->entries) {
		@public_attrs = $entry->attributes;
	}

	for my $attr (sort @private_attrs) {
		$attr =~ /^acs/ and next;
		my $public = ($attr ~~ @public_attrs);
		printf "%s\t%s\n",
			$public?"":"\e[1;32mpriv\e[m", $attr;
	}
};

$commands{"user:chsh"} = sub {
	my ($shell) = @_;

	if ($shell) {
		if ($shell !~ m!^/.+!) {
			die "error: shell must be an absolute filesystem path\n";
		}
		elsif ($shell !~ m!^/bin/(ba)?sh$!) {
			warn "warning: shell might not be available on other servers\n";
		}

		$ldap = connect_auth;
		my $dn = user_dn(whoami);
		my %entry = (loginShell => $shell);

		print "Changing shell for ".whoami." to $shell\n";
		my $res = $ldap->modify($dn, replace => \%entry);
		if ($res->is_error) { die ldap_errmsg($res, $dn); }
		return 0;
	}
	else {
		$ldap = connect_auth;
		my $dn = user_dn(whoami);
		my $res = $ldap->search(base => $dn, scope => "base",
			filter => q(objectClass=posixAccount));
		$res->is_error and die ldap_errmsg($res, $dn);
		for my $entry ($res->entries) {
			$shell = $entry->get_value("loginShell");
		}
		$shell //= "not set.";
		print "Your current shell is $shell\n";
		return 0;
	}
};

$commands{"help"} = sub {
	print qq{Usage: cluenet <command>

ACCESS LISTS
	read	access <host/service>...
	modify	access <host/service>... [+-]<user>...
	list	acl <host>...
	create	acl:create <host/service>...
	delete	acl:delete <host/service>...

USER ACCOUNT
	view	user <user>
	shell	user:chsh <shell>
	privacy	user:acs [<attribute=value>...]

SERVERS
	view	server <host>
	add	server:create <host> --owner <owner>

MISCELLANEOUS
	whoami
};

	return 0;
};

$commands{"whoami"} = sub {
	$ldap = connect_auth();
	print $ldap->who_am_i->response."\n";
	return 0;
};

### Main code

$cmd = shift(@ARGV) // "help";

if (defined $commands{$cmd}) {
	$exit = $commands{$cmd}->(@ARGV);
	$ldap and $ldap->unbind;
	exit $exit ? 1 : 0;
} else {
	die "Unknown command '$cmd'\n";
}
