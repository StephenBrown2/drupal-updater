#!/usr/bin/perl
use warnings;
use strict;

use Term::ReadKey;
use Getopt::Long;

our $DRUSH_BIN = '';
our $GIT_BIN = '';
my ($blind,$dryrun,$nodb,$verbose,$author,$coreonly,$securityonly);
my $options = GetOptions (
                 "blind" => \$blind,
                 "test|dryrun" => \$dryrun,
                 "nodb" => \$nodb,
                 "verbose" => \$verbose,
                 "author=s" => \$author,
                 "core-only" => \$coreonly,
                 "security-only" => \$securityonly
              );

sub get_drush_up_status {
    my %update_info;

    open (DRUSHUPSTATUS, "$DRUSH_BIN pm-update --cache --pipe 2>/dev/null |");

    while (<DRUSHUPSTATUS>) {
        chomp;
        next if /^\s*$/;
        my @info = split;
        next if ($info[0] =~ /PHP/) || ($info[5]);
        next if &module_is_locked($info[0]);
        $info[3] =~ s/-/ /g; # Strip out the dashes used to make --pipe space-separated
        $update_info{$info[0]}{'machine_name'} = $info[0];
        $update_info{$info[0]}{'current_version'} = $info[1];
        $update_info{$info[0]}{'new_version'} = $info[2];
        $update_info{$info[0]}{'update_status'} = $info[3];
    }

    close DRUSHUPSTATUS;

    return %update_info;
}

sub module_path {
    my $module = shift;
    
    my @info = split /\s:|\n/, `$DRUSH_BIN pm-info $module 2>/dev/null`;

    my $path = 0;
    for (@info) {
        chomp;
        s/^\s*|\s*$|\s{2,}//g;
        $path = $_ if $path;
        last if $path;
        $path = 1 if $_ eq 'Path';
    }

    return $path;
}

sub drush_status {
    my @oa = split /\s+:|\n/, `$DRUSH_BIN status 2>/dev/null`;

    my ($slash, $prev_slash);
    my $index = 0;
    for (@oa) {
        chomp;
        s/^\s*|\s*$|\s{2,}//g;
        $_ = 'none' if $_ eq '';
        if ( $_ =~ m/^\// ) { # Sometimes there are more than one value per key
            $slash = 1;       # These are generally file paths
        } else {
            $slash = 0;
        }
        if ( $slash and $prev_slash ) { # Combine multiple sequential file paths
            splice @oa, $index-1, 2, $oa[$index-1]." $_";
            $slash = 0;
        }
        $prev_slash = $slash;
        $index++;
    }

    map { s/^\s*|\s*$|\s{2,}//g } @oa; # Redo the space cleanup

    my %oh = @oa;

    for my $k ( keys %oh ) {
        (my $nk = lc $k) =~ s/ /_/g;
        $oh{$nk} = delete $oh{$k};
    }

    return %oh;
}

sub module_is_locked {
    my $module = shift;

    my %drush_status = &drush_status;
    my $module_path = &module_path($module);

    my $drush_lockfile = $drush_status{'drupal_root'}.'/'.$module_path.'/.drush-lock-update';

    if (-e $drush_lockfile ) {
        return 1;
    } else {
        return 0;
    }
}

sub get_modules_list {
    my %modules_info;

    open (DRUSHPMLIST, "COLUMNS=1000 $DRUSH_BIN pm-list 2>/dev/null |");

    while (<DRUSHPMLIST>) {
        chomp;
        my @temp = split /\s{2,}/;
        next unless (defined $temp[0] && defined $temp[1]);
        next if ($temp[0] =~ /Package/ && $temp[1] =~ /Name/);
        my ($name, $module) = ($temp[1] =~ /(.*)\(([^)]+)\)$/);
        $temp[4] = 'None' unless defined $temp[4];
        my @info = ($module, $name, $temp[0], $temp[2], $temp[3], $temp[4]);
        $info[1] =~ s/\s$//;
        $info[2] =~ s/^\s//;
        $modules_info{$info[0]}{'machine_name'} = $info[0];
        $modules_info{$info[0]}{'human_name'} = $info[1];
        $modules_info{$info[0]}{'package'} = $info[2];
        $modules_info{$info[0]}{'type'} = $info[3];
        $modules_info{$info[0]}{'install_status'} = $info[4];
        $modules_info{$info[0]}{'current_version'} = $info[5];
    }

    close DRUSHPMLIST;

    return %modules_info;
}

sub get_modules_info {
    my %drush_up = &get_drush_up_status;
    my %modules_info = &get_modules_list;
    my %return_hash;

    foreach my $name ( keys %drush_up ) {
        $drush_up{$name}{'human_name'} = $modules_info{$name}{'human_name'};
        $drush_up{$name}{'human_name'} = 'Drupal Core' if $name eq 'drupal'
    }

    # Sort the updates to do the more important ones first:
    # Unsupported, then Security, then regular (Bugfix) updates
    my $priority = 0;
    foreach my $key ( sort {$drush_up{$a}{'update_status'} cmp $drush_up{$b}{'update_status'}} keys %drush_up ) {
        if ($coreonly) { next unless $drush_up{$key}{'machine_name'} eq 'drupal'; }
        if ($securityonly) { next unless $drush_up{$key}{'update_status'} =~ m/SECURITY/; }
        my $message = sprintf "Update %s module (%s) from %s to %s - %s",
                    $drush_up{$key}{'human_name'},
                    $drush_up{$key}{'machine_name'},
                    $drush_up{$key}{'current_version'},
                    $drush_up{$key}{'new_version'},
                    $drush_up{$key}{'update_status'};

         $return_hash{$priority}{'module'} = $drush_up{$key}{'machine_name'};
         $return_hash{$priority}{'message'} = $message;
         $priority++;
    }
    return %return_hash;
}

sub has_drush {
    $DRUSH_BIN = qx/which drush/ or return 0;
    chomp($DRUSH_BIN);
    return 1;
}

sub is_drupal {
    if (qx/$DRUSH_BIN status --pipe/ =~ 'drupal_version') {
        return 1;
    } else {
        return 0;
    }
}

sub has_git {
    $GIT_BIN = qx/which git/ or return 0;
    chomp($GIT_BIN);
    return 1;
}

sub is_git {
    if (qx/$GIT_BIN rev-parse --is-inside-work-tree/ =~ 'true') {
        return 1;
    } else {
        return 0;
    }
}

sub git_root_dir {
    if (&is_git) {
        my $dir = qx/$GIT_BIN rev-parse --show-toplevel/;
        chomp $dir;
        return $dir;
    }
}

sub git_is_dirty {
    if (&is_git) {
        system($GIT_BIN, "diff-index", "--quiet", "HEAD", "--");
        my $exit_code = $? >> 8;
        return $exit_code;
    }
}

# Borrowed and modified from git itself (Git 1.8.0, but code added in Oct 2010)
# Ref: http://stackoverflow.com/a/3879077
# Ref: http://stackoverflow.com/a/2659808
sub require_clean_work_tree {
    system("$GIT_BIN rev-parse --verify HEAD >/dev/null 2>&1");
    exit 1 unless ($? >> 8) == 0;
    system("$GIT_BIN update-index -q --ignore-submodules --refresh >/dev/null 2>&1");

    my $err = 0;
    my $exit = 0;

    system("$GIT_BIN diff-files --quiet --ignore-submodules >/dev/null 2>&1");
    $exit = $? >> 8;

    if ($exit) {
        print STDERR "Cannot continue: You have unstaged changes.\n";
        $err = 1;
    }

    system("$GIT_BIN diff-index --cached --quiet --ignore-submodules HEAD -- >/dev/null 2>&1");
    $exit = $? >> 8;

    if ($exit) {
        if ( $err == 0 ) {
            print STDERR "Cannot continue: Your index contains uncommitted changes.\n";
        } else {
            print STDERR "Additionally, your index contains uncommitted changes.\n";
        }
        $err = 1;
    }

    # Check for untracked files in working tree, since we will by default
    #  be adding all files to the commit
    # Note: Not taken from git, but from second SO reference above
    system("$GIT_BIN ls-files --exclude-standard --others --error-unmatch \$(git rev-parse --show-toplevel) >/dev/null 2>&1");
    $exit = $? >> 8;

    if ( ! $exit ) {
        if ( $err == 0 ) {
            print STDERR "Cannot continue: You have untracked files.\n";
        } else {
            print STDERR "Additionally, you have untracked files.\n";
        }
        $err = 1;
    }

    if ( $err == 1 ) {
        print "Please commit, remove, or stash them before continuing.\n";
        print "If they are not your changes, please contact the developer responsible for them.\n";
        exit 1;
    }
}

sub current_branch {
    if (&is_git) {
        my $branch = qx($GIT_BIN rev-parse --abbrev-ref HEAD 2>/dev/null);
        chomp $branch;
        return $branch;
    }
}

sub update_module {
    my $module_name = shift;
    my $blank_lines = 0;
    my $blanks_needed = 3;
    
    if ($dryrun) {
        print "DRYRUN: '$DRUSH_BIN pm-update -n --cache $module_name 2>&1 |'\n";
        open (DRUSHUP, "$DRUSH_BIN pm-update -n --cache $module_name 2>&1 |");
    } else {
        open (DRUSHUP, "$DRUSH_BIN pm-update -y --cache $module_name 2>&1 |");
    }

    while (<DRUSHUP>) {
        chomp;
        if ($verbose) {
            if ( /^\s*$/ ) {
                $blank_lines++;
            } else {
                $blank_lines = 0 if $blank_lines < $blanks_needed;
            }
            print "$_\n" if $blank_lines >= $blanks_needed;
        }
    }

    close DRUSHUP;

    # Do some cleanup, don't need the tarball after update
    my %drush_status = &drush_status;
    my $module_path = &module_path($module_name);
    my $cachefile = $drush_status{'drupal_root'}.'/'.$module_path.'*.tar.gz';

    if ($dryrun) {
        print "DRYRUN: rm -f $cachefile\n";
    } else {
        qx/rm -f $cachefile/;
    }
}

sub git_proper_user {
    my $login = getlogin || getpwuid($<) || "unknown user";
    my $name;
    my $email;
    my %return;

    if ( -e "/home/$login/.gitconfig" ) {
        # Get the git author information from the actual user's gitconfig, useful if sudo'ed
        $name = qx($GIT_BIN config --file /home/$login/.gitconfig --get user.name);
        $email = qx($GIT_BIN config --file /home/$login/.gitconfig --get user.email);
    } elsif ( -e "/$login/.gitconfig" ) {
        # Fallback for root user if actual user isn't detected
        $name = qx($GIT_BIN config --file /$login/.gitconfig --get user.name);
        $email = qx($GIT_BIN config --file /$login/.gitconfig --get user.email);
    } else {
        # Fallback if things really break for some reason
        $name = qx($GIT_BIN config --get user.name);
        $email = qx($GIT_BIN config --get user.email);
    }

    chomp( $name, $email );
    $return{'name'} = $name;
    $return{'email'} = $email;

    return %return;
}

sub git_commit {
    my $update_info = shift || die("No message passed to git commit");
    my $git_root = &git_root_dir;
    my %user = &git_proper_user;
    my $username = $user{'name'};
    my $useremail = $user{'email'};
    my $authorstring = $author ? $author : "$username <$useremail>";

    if ($dryrun) {
        print "DRYRUN: $GIT_BIN add -A $git_root\n";
        print "DRYRUN: $GIT_BIN commit --author=\"$authorstring\" -m \"$update_info\"\n";
    } else {
        print "VERBOSE: $GIT_BIN add -A $git_root\n" if $verbose;
        my $git_add_output = qx($GIT_BIN add -A $git_root);
        print $git_add_output if $verbose;
        print "VERBOSE: $GIT_BIN commit --author=\"$authorstring\" -m \"$update_info\"\n" if $verbose;
        my $git_commit_output = qx($GIT_BIN commit --author="$authorstring" -m "$update_info");
        print $git_commit_output if $verbose;
    }
}

sub press_any_key {
    print "press any key to continue, or CTRL-C to quit.\n";
    ReadMode('cbreak'); # Mode 4, Turn off controls keys
    my $key = ReadKey(0);
    ReadMode('normal'); # Mode 0, Reset tty mode before exiting
}

sub check_requirements {
    if (&has_drush) {
        print "Drush is installed: $DRUSH_BIN\n";
    } else {
        print "Could not find drush, exiting.\n";
        exit;
    }
    if (&has_git) {
        print "Git is installed: $GIT_BIN\n";
    } else {
        print "Could not find git, exiting.\n";
        exit;
    }
    if (&is_drupal) {
        print "This is a Drupal site\n";
    } else {
        print "This does not appear to be a Drupal installation, exiting.\n";
        exit;
    }
    if (&is_git) {
        print "This site is controlled by git\n";
        print "The current branch is: ".&current_branch."\n";
        &require_clean_work_tree;
    } else {
        print "This is not a git repository, exiting.\n";
    }
}

sub post_update {
    my $module = shift;

    print "Updating database...\n";
    qx($DRUSH_BIN \@sites -y updatedb) unless ($dryrun or $nodb);

    print "Clearing cache...\n";
    qx($DRUSH_BIN \@sites -y cache-clear all) unless $dryrun;

    print "\nPlease verify that nothing broke,\n";
    print "especially anything related to: $module\nThen ";
    &press_any_key;
}

sub main {
    my $total_time = time;

    if ($author && $author !~ /^[^<]+<[^@]+@[^>]+>$/) {
        die "Invalid author string format. Must be in the form of 'Real Name <email\@address>'\n";
    }

    print "Checking requirements... \n";
    &check_requirements;

    print "Getting drush update status... ";
    my $time = time;
    my %info = &get_modules_info;
    $time = time - $time;
    print "took $time seconds.\n";

    my $num_updates = scalar(keys %info);
    print "There are $num_updates updates.\n" if ($num_updates > 1);

    print "Updating all modules blindly.\n" if $blind;

    $blind = 1 if ($num_updates == 1);
    my $modules = '';

    foreach my $k (sort keys %info) {
        printf "%s\n", $info{$k}{'message'};
        &update_module($info{$k}{'module'});
        $modules .= $info{$k}{'module'}.", ";
        printf "Committing update to %s\n", $info{$k}{'module'};
        &git_commit($info{$k}{'message'});
        
        unless ($blind) {
            &post_update($info{$k}{'module'});
            print "\nContinuing...\n";
        }
    }

    if ($blind) {
        my @commas = ($modules =~ m/,/g);
        my $commas = scalar(@commas);
        $modules =~ s/([^ ]+,) $/or $1/ if ($commas > 1);
        &post_update($modules);
    }

    print "\nAll done!\n";
    $total_time = time - $total_time;
    print "Overall, $total_time seconds\n";

    unless ($dryrun) {
        print "\nHere is the git log summary:\n\n";
        system("$GIT_BIN log -n$num_updates");
    }
}

&main;
