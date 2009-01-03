#!/usr/local/bin/perl
# Blacklist email in spamtrap files, and whitelist mail in hamtraps, for all
# domains with spam emailed.

package virtual_server;
$main::no_acl_check++;
$no_virtualmin_plugins = 1;
require './virtual-server-lib.pl';
&foreign_require("mailboxes", "mailboxes-lib.pl");
&foreign_require("spam", "spam-lib.pl");

# Find the sa-learn command
$salearn = &has_command($spam::config{'sa_learn'} || "sa-learn");

# Parse command line
while(@ARGV) {
	$a = shift(@ARGV);
	if ($a eq "--debug") {
		$debug = 1;
		}
	elsif ($a eq "--no-delete") {
		$nodelete = 1;
		}
	else {
		$dnames{$a} = 1;
		}
	}

# For each domain with spam enabled and with the aliases, process the files
foreach $d (&list_domains()) {
	# Skip if this domain wasn't on the list given
	next if (%dnames && !$dnames{$d->{'dom'}});

	# Is this domain suitable
	if (!$d->{'spam'}) {
		print STDERR "$d->{'dom'}: spam filtering is not enabled\n"
			if ($debug);
		next;
		}
	$st = &get_spamtrap_aliases($d);
	if ($st != 1) {
		print STDERR "$d->{'dom'}: missing spamtrap aliases\n"
			if ($debug);
		next;
		}

	if (!$salearn) {
		print STDERR "The sa-learn command was not found ",
			     "on your system\n";
		exit(1);
		}

	# Get users and alias domains for the domain
	@users = &list_domain_users($d, 0, 0, 1, 1);
	@aliasdoms = &get_domain_by("alias", $d->{'id'});

	# Find and read the spam folder and ham folder
	print STDERR "$d->{'dom'}: processing spam file\n" if ($debug);
	$spamf = { 'file' => &spam_alias_file($d),
		   'type' => 0 };
	@spammails = &mailboxes::mailbox_list_mails(undef, undef, $spamf);
	print STDERR "$d->{'dom'}: ",scalar(@spammails)," messages in ",
		     $spamf->{'file'},"\n" if ($debug);
	foreach $m (@spammails) {
		$m->{'spamtrap'} = 1;
		}
	@mails = @spammails;
	print STDERR "$d->{'dom'}: processing ham file\n" if ($debug);
	$hamf = { 'file' => &ham_alias_file($d),
		  'type' => 0 };
	@hammails = &mailboxes::mailbox_list_mails(undef, undef, $hamf);
	print STDERR "$d->{'dom'}: ",scalar(@hammails)," messages in ",
		     $hamf->{'file'},"\n" if ($debug);
	push(@mails, @hammails);

	foreach $m (@mails) {
		# Find the Virtualmin user for the sender or recipient
		print STDERR "$d->{'dom'}: id=",
			     "$m->{'header'}->{'message-id'}\n" if ($debug);
		$user = undef;
		foreach $h ('from', 'to', 'cc') {
			@sp = &mailboxes::split_addresses($m->{'header'}->{$h});
			foreach $e (map { $_->[0] } @sp) {
				$user ||= &find_user_by_email(
						$e, \@users, \@aliasdoms);
				last if ($user);
				}
			if ($user) {
				$what = $h eq 'from' ? 'from' : 'to';
				last;
				}
			}
		print STDERR "$d->{'dom'}: user=",
		    ($user ? $user->{'user'} : "")," what=$what\n" if ($debug);
		next if (!$user);

		# For each message, find the attached mail if there is one and
		# if this email was forwarded by a Virtualmin user.
		&mailboxes::parse_mail($m, undef, 1);
		@learnm = ( );
		if ($what eq 'from') {
			foreach $a (@{$m->{'attach'}}) {
				if ($a->{'type'} eq 'message/rfc822') {
					$lm = &mailboxes::extract_mail(
						$a->{'data'});
					push(@learnm, $lm);
					}
				}
			}
		@learnm = ( $m ) if (!@learnm);

		# Feed to sa-learn --spam or --ham, run as the sender
		@senders = ( );
		foreach $lm (@learnm) {
			print STDERR "$d->{'dom'}: $user->{'user'}: subject=",
				   "$lm->{'header'}->{'subject'}\n" if ($debug);
			local $cmd = $m->{'spamtrap'} ? "$salearn --spam"
						      : "$salearn --ham";
			$cmd = &command_as_user($user->{'user'}, 0, $cmd);
			$temp = &transname();
			&mailboxes::send_mail($lm, $temp);
			&set_ownership_permissions(
				$user->{'uid'}, $user->{'gid'}, 0700, $temp);
			$out = &backquote_command("$cmd <$temp 2>&1");
			$ex = $?;
			&unlink_file($temp);
			if ($debug) {
				$out =~ s/\r?\n/ /g;
				print STDERR "$d->{'dom'}: $user->{'user'}: ",
					($ex ? "ERROR" : "OK")," $out","\n";
				}
			push(@senders, map { $_->[0] }
					&mailboxes::split_addresses(
					  $lm->{'header'}->{'from'}));
			}

		# Update black or white list, for senders who are not local
		$cf = $m->{'spamtrap'} ? 'spam_trap_black' : 'ham_trap_white';
		$dir = $m->{'spamtrap'} ? 'blacklist_from' : 'whitelist_from';
		if ($config{$cf}) {
			$spamcfile = "$spam_config_dir/$d->{'id'}/".
				     "virtualmin.cf";
			$conf = &spam::get_config($config{$cf} == 2 ? undef :
						   $spamcfile);
			@from = map { @{$_->{'words'}} }
				    &spam::find($dir, $conf);
			%already = map { $_, 1 } @from;
			$added = 0;
			foreach $e (&unique(@senders)) {
				$euser = &find_user_by_email(
					$e, \@users, \@aliases);
				if (!$euser && !$already{$e}) {
					push(@from, $e);
					print STDERR "$d->{'dom'}: Adding $e",
					  " to $dir\n" if ($debug);
					$added++;
					}
				}
			if ($added) {
				if ($config{$cf} == 1) {
					# So adding is to right file
					$spam::add_cf = $spamcfile;
					}
				&spam::save_directives($conf, $dir, \@from, 1);
				}
			}
		}
	&flush_file_lines();

	# Delete both folders
	if (!$nodelete) {
		&mailboxes::mailbox_empty_folder($spamf);
		&mailboxes::mailbox_empty_folder($hamf);
		}
	}

# find_user_by_email(email, &users, &aliases)
sub find_user_by_email
{
local ($e, $users, $aliasdoms) = @_;
foreach my $u (@$users) {
	foreach my $ee ($u->{'email'}, @{$u->{'extraemail'}}) {
		if ($ee eq $e) {
			return $u;
			}
		# Check for same email address in alias domain
		local ($mb, $dname) = split(/\@/, $ee);
		foreach my $ad (@aliasdoms) {
			if ($e eq $mb."\@".$ad->{'dom'}) {
				return $u;
				}
			}
		}
	}
return undef;
}

