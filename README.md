Drupal update and git commit script
===================================

This script uses the black magic or Perl, combined with the dexterity of Drush
and the wonders of git, to update modules in a Drupal installation and commit
each one to the git repository, assuming there is one.


Assumptions:
------------
1. Drush and git are installed and accessible in the PATH of the script.
2. The current directory is at least the root of a Drupal installation,
and actions such as 'drush up' can take place. This means, for now,
that this does not work in the root of a multi-site installation,
you need to be inside a site directory. This should change soon.
3. The current directory is inside a git repository.
4. There are no uncommitted changes or untracked files, in other words,
the git repository must be 'clean'.

Usage:
------
To use this script, simply run it from the root directory of the site
you wish to upgrade, and after each module is updated, the script will
update the database and clear cache, then ask you to verify that the site
is still in working order. At the end of it all, it will show you the git log.

If you wish to skip the individual checks, you can pass the '--blind' option
to have it run through all the updates, still committing each one
individually, but waiting to update the database and clear cache till the
end, at which point it will pause again and ask you to verify the site,
before showing you the git log.

You may also pass the '--dryrun' option, to skip the meat and potatoes
of the script and instead just show you the steps it would perform,
or '--nodb' to simply skip the database update.

Options:
--------
<pre>
--blind  | runs through all updates without pausing to check for breakage in between
--dryrun | runs through the motions without actually performing any changes
--nodb   | runs through all code updates, but does not update the database
</pre>

TODO:
-----
* Help information with '-h' and '--help' options
* Multisite support
* Back up database before starting
* Only show git log for completed updates, if interrupted.
