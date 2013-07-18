#!/usr/bin/perl
use warnings;
use strict;

use Cwd qw(abs_path);
use POSIX qw(strftime);
use Readonly;
use Term::ReadKey;
use Getopt::Long::Descriptive;
use JSON::XS;
use Data::Dumper;

# These are internally used constants for Drupal: core/modules/update/update.module

# URL to check for updates, if a given project doesn't define its own.
Readonly my $UPDATE_DEFAULT_URL => 'http://updates.drupal.org/release-history';

# Project is missing security update(s).
Readonly my $UPDATE_NOT_SECURE => 1;

# Current release has been unpublished and is no longer available.
Readonly my $UPDATE_REVOKED => 2;

# Current release is no longer supported by the project maintainer.
Readonly my $UPDATE_NOT_SUPPORTED => 3;

# Project has a new release available, but it is not a security release.
Readonly my $UPDATE_NOT_CURRENT => 4;

# Project is up to date.
Readonly my $UPDATE_CURRENT => 5;

# Project's status cannot be checked.
Readonly my $UPDATE_NOT_CHECKED => -1;

# No available update data was found for project.
Readonly my $UPDATE_UNKNOWN => -2;

# There was a failure fetching available update data for this project.
Readonly my $UPDATE_NOT_FETCHED => -3;

# We need to (re)fetch available update data for this project.
Readonly my $UPDATE_FETCH_PENDING => -4;

Readonly my $status_codes => { $UPDATE_NOT_SECURE    => 'Project is missing security update(s).',
                               $UPDATE_REVOKED       => 'Current release has been unpublished and is no longer available.',
                               $UPDATE_NOT_SUPPORTED => 'Current release is no longer supported by the project maintainer.',
                               $UPDATE_NOT_CURRENT   => 'Project has a new release available, but it is not a security release.',
                               $UPDATE_CURRENT       => 'Project is up to date.',
                               $UPDATE_NOT_CHECKED   => 'Project\'s status cannot be checked.',
                               $UPDATE_UNKNOWN       => 'No available update data was found for project.',
                               $UPDATE_NOT_FETCHED   => 'There was a failure fetching available update data for this project.',
                               $UPDATE_FETCH_PENDING => 'We need to (re)fetch available update data for this project.',
                          };

our $DEBUG = 0;
our $DRUSH_BIN = '';
our $GIT_BIN = '';

my ($opt, $usage) = describe_options (
        '%c %o',
        [ 'blind', 'runs through all updates without pausing to check for breakage in between' ],
        [ 'dryrun|dry-run|test', 'runs through the motions without actually performing any changes' ],
        [ 'nodb|no-db', 'runs through all code updates, but does not update the database' ],
        [ 'coreonly|core-only', 'shows only core updates (i.e. the project name = drupal)' ],
        [ 'securityonly|security-only', 'shows only security updates (i.e. the update status =~ SECURITY)' ],
        [ 'enabledonly|enabled-only', 'shows only updates for enabled and installed modules' ],
        [ 'notifyemail|notify|email=s', 'specify one or email addresses, separated by commas, to send the log to' ],
        [ 'keeplog|log', 'saves the update log to a file, and prints the location at the end' ],
        [ 'author=s', 'set git commit author string, use when unable to automatically find it correctly' ],
        [ 'verbose|v', 'print more information from drush during run' ],
        [ 'help|h|?', 'print this help message and exit' ],
    );

print($usage->text), exit if $opt->help;

my ($blind, $dryrun, $keeplog, $nodb, $verbose, $author, $coreonly,
        $securityonly, $notifyemail) =
   ($opt->blind, $opt->dryrun, $opt->keeplog, $opt->nodb, $opt->verbose,
        $opt->author, $opt->coreonly, $opt->securityonly, $opt->notifyemail);

# Set up logfile
my $timenow = strftime("%FT%T", localtime);
my $timefile = $timenow;
   $timefile =~ tr/:/-/;
my $tmpfile = "/tmp/drupal_updater-$timefile.log";

open(my $log, ">>", $tmpfile);

sub has_drush {
    $DEBUG and print( (caller(0))[3]."\n" );

    $DRUSH_BIN = qx/which drush/ or return 0;
    chomp($DRUSH_BIN);
    return 1;
}

sub get_drush_version {
    $DEBUG and print( (caller(0))[3]."\n" );

    my $drush_version = qx/$DRUSH_BIN version --format=string --strict=0/;
    chomp $drush_version;
    return $drush_version;
}

sub is_drush_6 {
    $DEBUG and print( (caller(0))[3]."\n" );

    my $drush_version = &get_drush_version;
    if ( $drush_version =~ /^6/ ) {
        return 1;
    } else {
        return 0;
    }
}

sub is_drupal {
    $DEBUG and print( (caller(0))[3]."\n" );

    if (qx/$DRUSH_BIN status --pipe/ =~ /drupal[_-]version/) {
        return 1;
    } else {
        return 0;
    }
}

sub has_git {
    $DEBUG and print( (caller(0))[3]."\n" );

    $GIT_BIN = qx/which git/ or return 0;
    chomp($GIT_BIN);
    return 1;
}

sub is_git {
    $DEBUG and print( (caller(0))[3]."\n" );

    if (qx/$GIT_BIN rev-parse --is-inside-work-tree/ =~ 'true') {
        return 1;
    } else {
        return 0;
    }
}

sub git_root_dir {
    $DEBUG and print( (caller(0))[3]."\n" );

    if (&is_git) {
        my $dir = qx/$GIT_BIN rev-parse --show-toplevel/;
        chomp $dir;
        return $dir;
    }
}

sub git_is_dirty {
    $DEBUG and print( (caller(0))[3]."\n" );

    if (&is_git) {
        system($GIT_BIN, "diff-index", "--quiet", "HEAD", "--");
        my $exit_code = $? >> 8;
        return $exit_code;
    }
}

sub press_any_key {
    $DEBUG and print( (caller(0))[3]."\n" );

    print "press Enter/Return key to continue, or type 'quit' to quit.\n";
    my $key = <STDIN>;
    if ($key =~ /^q.*$/i) {
        &end_sub('quit');
    }
}

sub check_requirements {
    $DEBUG and print( (caller(0))[3]."\n" );

    if (&has_drush) {
        print "Drush is installed: $DRUSH_BIN\n";
    } else {
        print "Could not find drush, exiting.\n";
        exit;
    }
    if (&is_drush_6) {
        print "Drush is up to date: ".&get_drush_version."\n";
    } else {
        print "This script relies on outputformats, which were introduced in\n".
              "Drush 6. Please update your drush to use this script. Exiting.\n";
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

##########
# Git related methods
##########

sub git_proper_user {
    $DEBUG and print( (caller(0))[3]."\n" );

    my $login = getlogin || getpwuid($<) || "unknownuser";
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
    $DEBUG and print( (caller(0))[3]."\n" );

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

sub post_update {
    $DEBUG and print( (caller(0))[3]."\n" );

    my $module = shift;

    print "Updating database...\n";
    qx($DRUSH_BIN \@sites -y updatedb) unless ($dryrun or $nodb);

    print "Clearing cache...\n";
    qx($DRUSH_BIN \@sites -y cache-clear all) unless $dryrun;

    print "\nPlease verify that nothing broke,\n";
    print "especially anything related to: $module\nthen ";

    unless ( $blind ) {
        &press_any_key;
    } else {
        print "alert the appropriate site owner to review.\n";
    }
}

# Borrowed and modified from git itself (Git 1.8.0, but code added in Oct 2010)
# Ref: http://stackoverflow.com/a/3879077
# Ref: http://stackoverflow.com/a/2659808
sub require_clean_work_tree {
    $DEBUG and print( (caller(0))[3]."\n" );

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
    $DEBUG and print( (caller(0))[3]."\n" );

    if (&is_git) {
        my $branch = qx($GIT_BIN rev-parse --abbrev-ref HEAD 2>/dev/null);
        chomp $branch;
        return $branch;
    }
}

##########
# Drush related methods
##########

sub json_from_drush {
    $DEBUG and print( (caller(0))[3]."\n" );

    my $drush_command = shift;
    my $override      = shift or 0;
    my $fh;
    unless ( $override ) {
        open( $fh, "-|", "$DRUSH_BIN $drush_command --format=json 2>/dev/null" );
    } else {
        open( $fh, "-|", "$drush_command" );
    }
    my $json = <$fh>;
    my $decoded_json = decode_json( $json );
    close( $fh );

    return $decoded_json;
}

sub module_path {
    $DEBUG and print( (caller(0))[3]."\n" );

    my $module = shift;

    my $drush_command = "pm-info $module";
    my $decoded_json = &json_from_drush($drush_command);

    my $path = $decoded_json->{$module}->{'path'};

    return $path;
}

sub get_drush_status {
    $DEBUG and print( (caller(0))[3]."\n" );

    my $drush_command = 'status';

    my $decoded_json = &json_from_drush($drush_command);

    return $decoded_json;
}

sub module_is_locked {
    $DEBUG and print( (caller(0))[3]."\n" );

    my $module = shift;
    return 0 if $module eq 'drupal'; # Can't lock drupal core
    my $drush_status = &get_drush_status;
    my $drupal_root  = $drush_status->{'root'};
    my $module_path  = &module_path($module);

    my $drush_lockfile = "$drupal_root/$module_path/.drush-lock-update";

    if (-e $drush_lockfile) {
        return 1;
    } else {
        return 0;
    }
}

sub get_modules_list {
    $DEBUG and print( (caller(0))[3]."\n" );

    my %modules_info;

    my $drush_command = 'pm-list';

    my $decoded_json = &json_from_drush($drush_command);

    foreach my $module ( keys %$decoded_json ) {
        $modules_info{$module}{'machine_name'}    = $module;
        $modules_info{$module}{'human_name'}      = $decoded_json->{$module}->{'name'};
        $modules_info{$module}{'package'}         = $decoded_json->{$module}->{'package'};
        $modules_info{$module}{'type'}            = $decoded_json->{$module}->{'type'};
        $modules_info{$module}{'install_status'}  = $decoded_json->{$module}->{'status'};
        $modules_info{$module}{'current_version'} = $decoded_json->{$module}->{'version'};
    }

    return %modules_info;
}

sub get_drush_pm_updatestatus {
    $DEBUG and print( (caller(0))[3]."\n" );

    my $updatestatus_ref;
    my %updatestatus;

    my $security = $opt->securityonly ? '--security-only' : '';
    my $core = $opt->coreonly ? 'drupal' : '';

    my $drushupscommand = "$DRUSH_BIN \@sites pm-updatestatus -y --format=json ".
                          "$security $core 2>/dev/null | grep -Ev ".
                          "'(You are|^  |Continue)' | sed -e 's/.*>> //g'";

    $updatestatus_ref = &json_from_drush($drushupscommand, 'true');

    # hash = {
    #      'module' => {
    #                     'name' => 'machine_name',
    #                     'existing_version' => 'current_version',
    #                     'title' => 'human_name',
    #                     'label' => 'human_name (machine_name)',
    #                     'status_msg' => 'update_status',
    #                     'status' => 'status_code',
    #                     'candidate_version' => 'new_version'
    #                   },

    foreach my $key ( keys %$updatestatus_ref ) {
        $DEBUG and print "\nChecking module: $key\n";
        # Remove irrelevant updates: NOT_CHECKED, UNKNOWN,
        # NOT_FETCHED, FETCH_PENDING, CURRENT
        if ($updatestatus_ref->{$key}->{'status'} < $UPDATE_NOT_SECURE or
            $updatestatus_ref->{$key}->{'status'} == $UPDATE_CURRENT) {
            $DEBUG and print $status_codes->{$updatestatus_ref->{$key}->{'status'}};
            $DEBUG and print "\nSkipping.\n";
            next;
        }
        # Remove locked updates
        if (&module_is_locked($key)) {
            $DEBUG and print "Module is locked.\n";
            $DEBUG and print "Skipping.\n";
            next;
        }
        # Take care of the edge case where --security-only and --core-only are
        # specified and drupal is only NOT_CURRENT, not NOT_SECURE.
        if ($opt->securityonly and $updatestatus_ref->{$key}->{'status'} != $UPDATE_NOT_SECURE) {
            $DEBUG and print "Module is not insecure.\n";
            $DEBUG and print "Skipping.\n";
            next;
        }
        $DEBUG and print
        $status_codes->{$updatestatus_ref->{$key}->{'status'}}."\n";
        $updatestatus{$key}{'label'}            = $updatestatus_ref->{$key}->{'label'};
        $updatestatus{$key}{'human_name'}       = $updatestatus_ref->{$key}->{'title'};
        $updatestatus{$key}{'machine_name'}     = $updatestatus_ref->{$key}->{'name'};
        $updatestatus{$key}{'current_version'}  = $updatestatus_ref->{$key}->{'existing_version'};
        $updatestatus{$key}{'new_version'}      = $updatestatus_ref->{$key}->{'candidate_version'};
        $updatestatus{$key}{'update_status'}    = $updatestatus_ref->{$key}->{'status_msg'};
        $updatestatus{$key}{'status_code'}      = $updatestatus_ref->{$key}->{'status'};
    }

    return %updatestatus;
}

sub get_modules_info {
    $DEBUG and print( (caller(0))[3]."\n" );

    my %return_hash;
    my %temp_hash;
    my %drush_ups = &get_drush_pm_updatestatus;
    my $priority = 0;

    # Prepare the hash for sorting
    foreach my $key ( keys %drush_ups ) {
        $temp_hash{$drush_ups{$key}{'status_code'}}{$key} = $drush_ups{$key};
    }
    # Sort the updates to do the more important ones first:
    # Security, then Revoked, then Unsupported, then Available updates.
    # Then also sort by name.
    foreach my $code ( sort {$a <=> $b} keys %temp_hash ) {
        my $child_href = $temp_hash{$code};
        foreach my $module ( sort {$a cmp $b} keys %$child_href ) {
            # Create appropriate message for git commit and logging
            my $message = sprintf "Update %s from %s to %s - %s",
                          $child_href->{$module}{'label'},
                          $child_href->{$module}{'current_version'},
                          $child_href->{$module}{'new_version'},
                          $child_href->{$module}{'update_status'};

             $return_hash{$priority}{'module'} = $child_href->{$module}{'machine_name'};
             $return_hash{$priority}{'message'} = $message;
             $priority++;
         }
    }
    return %return_hash;
}

sub update_module {
    $DEBUG and print( (caller(0))[3]."\n" );

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
    my $drush_status = &get_drush_status;
    my $drupal_root = $drush_status->{'root'};
    my $module_path = &module_path($module_name);
    my $cachefile = "$drupal_root/$module_path*.tar.gz";

    if ($dryrun) {
        print "DRYRUN: rm -f $cachefile\n";
    } else {
        qx/rm -f $cachefile/;
    }
}

sub main {
    $DEBUG and print( (caller(0))[3]."\n" );

    my $total_time = time;

    if ($author && $author !~ /^[^<]+<[^@]+@[^>]+>$/) {
        die "Invalid author string format. Must be in the form of 'Real Name <email\@address>'\n";
    }

    print "Checking requirements... \n";
    &check_requirements;

    my %userinfo = &git_proper_user;

    print $log "=== DRY RUN ===\n" if $dryrun;
    print $log $timenow."\n";
    print $log "Drupal module updates performed by ".$userinfo{'name'}."\n";
    print $log qx($DRUSH_BIN vget --exact site_name);
    print $log "directory: ".abs_path()."\n\n";

    print "Getting drush update status... \n";
    my $time = time;

    system("$DRUSH_BIN",'vset','-y','--exact','update_check_disabled','1') unless $opt->enabledonly;

    my %info = &get_modules_info;
    $time = time - $time;
    print "took $time seconds.\n";

    our $num_updates = scalar(keys %info);
    my @updates;
    foreach my $k (sort keys %info) {
        push(@updates, $info{$k}{'module'});
    }

    if ($num_updates > 1) {
        my $list_updates = join(', ', @updates);
        print "There are $num_updates updates:\n";
        $~ = "UPDATELIST";
        write;
        format UPDATELIST =
   ~~^<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
   $list_updates

.
        $~ = "STDOUT";
    }
    print "Updating all modules blindly.\n" if $blind;

    $blind = 1 if ($num_updates == 1);
    my $modules = '';

    foreach my $k (sort keys %info) {
        printf "%s\n", $info{$k}{'message'};
        &update_module($info{$k}{'module'});
        $modules .= $info{$k}{'module'}.", ";
        printf "Committing update to %s\n", $info{$k}{'module'};
        &git_commit($info{$k}{'message'});
        print $log $info{$k}{'message'}."\n\n";

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

    &end_sub;
}

sub end_sub {
    $DEBUG and print( (caller(0))[3]."\n" );

    my $interrupt = shift;

    unless ($dryrun) {
        print "\nHere is the git log summary:\n\n";
        my $gitlog = qx($GIT_BIN log -n$main::num_updates --stat);
        print $gitlog;
        print $log $gitlog;
    }

    close $log;

    system("$DRUSH_BIN",'vdel','-y','--exact','update_check_disabled') unless $opt->enabledonly;

    print "\n";

    if ($interrupt) {
        print "Interrupted. There may be more updates to perform.\n";
    }
    if ($notifyemail) {
        print "Sending log to $notifyemail\n";
        system("mail -s 'Drupal Module Updates' $notifyemail < $tmpfile");
    }
    if ($keeplog) {
        print "Log stored in $tmpfile\n";
    } else {
        unlink $tmpfile;
    }

    print "Finished!\n\n";
    exit;
}

&main;
