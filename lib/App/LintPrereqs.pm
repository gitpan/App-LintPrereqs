package App::LintPrereqs;

our $DATE = '2014-12-18'; # DATE
our $VERSION = '0.18'; # VERSION

use 5.010001;
use strict;
use warnings;
use Log::Any qw($log);

use Config::IniFiles;
use File::Find;
use File::Which;
use Sort::Versions;
use Scalar::Util 'looks_like_number';

our %SPEC;
require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(lint_prereqs);

$SPEC{lint_prereqs} = {
    v => 1.1,
    summary => 'Check extraneous/missing prerequisites in dist.ini',
    description => <<'_',

Check [Prereqs / *] sections in your dist.ini against what's actually being used
in your Perl code (using Perl::PrereqScanner) and what's in Perl core list of
modules. Will complain if your prerequisites are not actually used, or already
in Perl core. Will also complain if there are missing prerequisites.

Designed to work with prerequisites that are manually written. Does not work if
you use AutoPrereqs.

Sometimes there are prerequisites that you know are used but can't be detected
by scan_prereqs, or you want to include anyway. If this is the case, you can
instruct lint_prereqs to assume the prerequisite is used.

    ;!lint-prereqs assume-used # even though we know it is not currently used
    Foo::Bar=0
    ;!lint-prereqs assume-used # we are forcing a certain version
    Baz=0.12

Sometimes there are also prerequisites that are detected by scan_prereqs, but
you know are already provided by some other modules. So to make lint-prereqs
ignore them:

    [Extras / lint-prereqs / assume-provided]
    Qux::Quux=0

_
    args => {
        perl_version => {
            schema => ['str*'],
            summary => 'Perl version to use (overrides scan_prereqs/dist.ini)',
        },
    },
    deps => {
        prog => 'scan_prereqs',
    },
};
require Perinci::Sub::DepChecker; use experimental 'smartmatch';  sub lint_prereqs {
    my %args = @_;
 my $_sahv_dpath = []; my $_w_res = undef; for (sort keys %args) { if (!/\A(-?)\w+(\.\w+)*\z/o) { return [400, "Invalid argument name (please use letters/numbers/underscores only)'$_'"]; } if (!($1 || $_ ~~ ['perl_version'])) { return [400, "Unknown argument '$_'"]; } } if (exists($args{'perl_version'})) { my $err_perl_version; ((defined($args{'perl_version'})) ? 1 : (($err_perl_version //= (@$_sahv_dpath ? '@'.join("/",@$_sahv_dpath).": " : "") . "Required but not specified"),0)) && ((!ref($args{'perl_version'})) ? 1 : (($err_perl_version //= (@$_sahv_dpath ? '@'.join("/",@$_sahv_dpath).": " : "") . "Not of type text"),0)); if ($err_perl_version) { return [400, "Argument 'perl_version' fails validation: $err_perl_version"]; } } my $_w_deps_res = Perinci::Sub::DepChecker::check_deps($App::LintPrereqs::SPEC{lint_prereqs}->{deps}); if ($_w_deps_res) { return [412, "Deps failed: $_w_deps_res"]; }    $_w_res = do {
    (-f "dist.ini")
        or return [412, "No dist.ini found. ".
                       "Are you in the right dir (dist top-level)? ".
                           "Is your dist managed by Dist::Zilla?"];

    my $cfg = Config::IniFiles->new(-file => "dist.ini", -fallback => "ALL");
    $cfg or return [
        500, "Can't open dist.ini: ".join(", ", @Config::IniFiles::errors)];

    my %mods_from_ini;
    my %assume_used;
    my %assume_provided;
    for my $section (grep {
        m!^(
              osprereqs \s*/\s* .+ |
              osprereqs(::\w+)+ |
              prereqs (?: \s*/\s* \w+)? |
              extras \s*/\s* lint[_-]prereqs \s*/\s* assume-(?:provided|used)
          )$!ix}
                         $cfg->Sections) {
        for my $param ($cfg->Parameters($section)) {
            my $v   = $cfg->val($section, $param);
            my $cmt = $cfg->GetParameterComment($section, $param) // "";
            #$log->tracef("section=$section, param=$param, v=$v, cmt=$cmt");
            $mods_from_ini{$param}   = $v unless $section =~ /assume-provided/;
            $assume_provided{$param} = $v if     $section =~ /assume-provided/;
            $assume_used{$param}     = $v if     $section =~ /assume-used/ ||
                $cmt =~ /^;!lint-prereqs\s+assume-used\b/m;
        }
    }
    $log->tracef("mods_from_ini: %s", \%mods_from_ini);
    $log->tracef("assume_used: %s", \%assume_used);
    $log->tracef("assume_provided: %s", \%assume_provided);

    # assume package names from filenames, should be better and scan using PPI
    my %pkgs;
    find({
        #no_chdir => 1,
        wanted => sub {
            return unless /\.pm$/;
            my $pkg = $File::Find::dir;
            #$log->errorf("TMP:pkg=%s",$pkg);
            $pkg =~ s!^lib/?!!;
            $pkg =~ s!/!::!g;
            $pkg .= (length($pkg) ? "::" : "") . $_;
            $pkg =~ s/\.pm$//;
            $pkgs{$pkg}++;
        },
    }, "lib");
    $log->tracef("Packages: %s", \%pkgs);

    my %mods_from_scanned;
    my $sppath = "scan_prereqs";
    my $spcmd = "$sppath --combine .";
    $spcmd .= " t/*.t" if <t/*.t>;
    $spcmd .= " bin/*" if <bin/*>;
    $spcmd .= " examples/*" if <examples/*>;
    for (`$spcmd`) {
        chomp;
        /^([\w:]+)\s*=\s*(.+)/ or do {
            warn "Invalid line from $sppath: $_, skipped";
            next;
        };
        $mods_from_scanned{$1} = $2;
    }
    $log->tracef("mods_from_scanned: %s", \%mods_from_scanned);

    if ($mods_from_ini{perl} && $mods_from_scanned{perl}) {
        if (versioncmp($mods_from_ini{perl}, $mods_from_scanned{perl})) {
            return [500, "Perl version from dist.ini ($mods_from_ini{perl}) ".
                        "and scan_prereqs ($mods_from_scanned{perl}) mismatch"];
        }
    }

    my $perlv; # min perl v to use (& base corelist -v on), in x.yyyzzz format
    if ($args{perl_version}) {
        $log->tracef("Will assume perl %s (via perl_version argument)",
                     $args{perl_version});
        $perlv = $args{perl_version};
    } elsif ($mods_from_ini{perl}) {
        $log->tracef("Will assume perl %s (via dist.ini)",
                     $mods_from_ini{perl});
        $perlv = $mods_from_ini{perl};
    } elsif ($mods_from_scanned{perl}) {
        $log->tracef("Will assume perl %s (via scan_prereqs)",
                     $mods_from_scanned{perl});
        $perlv = $mods_from_scanned{perl};
    } else {
        $log->tracef("Will assume perl %s (from running interpreter's \$^V)",
                     $^V);
        if ($^V =~ /^v(\d+)\.(\d+)\.(\d+)/) {
            $perlv = sprintf("%d\.%03d%03d", $1, $2, $3)+0;
        } elsif (looks_like_number($^V)) {
            $perlv = $^V;
        } else {
            return [500, "Can't parse \$^V ($^V)"];
        }
    }

    my %core_mods;
    my $clpath = which("corelist")
        or return [412, "Can't find corelist in PATH"];
    my @clout = `corelist -v $perlv`;
    if ($?) {
        my $clout = join "", @clout;
        return [500, "corelist doesn't recognize perl version $perlv"]
            if $clout =~ /has no info on perl /;
        return [500, "Can't execute corelist command successfully"];
    }
    for (@clout) {
        chomp;
        /^([\w:]+)(?:\s+(\S+))?\s*$/ or next;
        #do {
        #    warn "Invalid line from $clpath: $_, skipped";
        #    next;
        #};
        $core_mods{$1} = $2 // 0;
    }
    $log->tracef("core modules in perl $perlv: %s", \%core_mods);

    my @errs;
    for my $mod (keys %mods_from_ini) {
        my $v = $mods_from_ini{$mod};
        next if $mod eq 'perl';
        $log->tracef("Checking mod from dist.ini: %s (%s)", $mod, $v);
        my $incorev = $core_mods{$mod};
        if (defined($incorev) && versioncmp($incorev, $v) >= 0) {
            push @errs, {
                module  => $mod,
                error   => "Core in perl $perlv ($incorev) but ".
                    "mentioned in dist.ini ($v)",
                remedy  => "Remove in dist.ini or lower perl version ".
                    "requirement",
            };
        }
        my $scanv = $mods_from_scanned{$mod};
        if (defined($scanv) && $scanv != 0 && versioncmp($v, $scanv)) {
            push @errs, {
                module  => $mod,
                error   => "Version mismatch between dist.ini ($v) ".
                    "and from scanned_prereqs ($scanv)",
                remedy  => "Fix either the code or version in dist.ini",
            };
        }
        unless (defined($scanv) || exists($assume_used{$mod})) {
            push @errs, {
                module  => $mod,
                error   => "Unused but listed in dist.ini",
                remedy  => "Remove from dist.ini",
            };
        }
    }

    for my $mod (keys %mods_from_scanned) {
        next if $mod eq 'perl';
        my $v = $mods_from_scanned{$mod};
        $log->tracef("Checking mod from scanned: %s (%s)", $mod, $v);
        if (exists $core_mods{$mod}) {
            my $incorev = $core_mods{$mod};
            if ($v != 0 && !$mods_from_ini{$mod} &&
                    versioncmp($incorev, $v) == -1) {
                push @errs, {
                    module  => $mod,
                    error   => "Version requested $v (from scan_prereqs) is ".
                        "higher than bundled with perl $perlv ($incorev)",
                    remedy  => "Specify in dist.ini with version=$v",
                };
            }
            next;
        }
        next if exists $pkgs{$mod};
        unless (exists($mods_from_ini{$mod}) ||
                    exists($assume_provided{$mod})) {
            push @errs, {
                module  => $mod,
                error   => "Used but not listed in dist.ini",
                remedy  => "Put '$mod=$v' in dist.ini",
            };
        }
    }

    my $rfopts = {
        table_column_orders  => [[qw/module error remedy/]],
    };
    my $resmeta = {
        "cmdline.exit_code" => @errs ? 500-300:0,
        result_format_options => {text=>$rfopts, "text-pretty"=>$rfopts},
    };
    [200, @errs ? "Extraneous/missing dependencies" : "OK", \@errs, $resmeta];
};      unless (ref($_w_res) eq "ARRAY" && $_w_res->[0]) { return [500, 'BUG: Sub App::LintPrereqs::lint_prereqs does not produce envelope']; } return $_w_res; }

1;
# ABSTRACT: Check extraneous/missing prerequisites in dist.ini

__END__

=pod

=encoding UTF-8

=head1 NAME

App::LintPrereqs - Check extraneous/missing prerequisites in dist.ini

=head1 VERSION

This document describes version 0.18 of App::LintPrereqs (from Perl distribution App-LintPrereqs), released on 2014-12-18.

=head1 SYNOPSIS

 # Use via lint-prereqs CLI script

=head1 FUNCTIONS


=head2 lint_prereqs(%args) -> [status, msg, result, meta]

Check extraneous/missing prerequisites in dist.ini.

Check [Prereqs / *] sections in your dist.ini against what's actually being used
in your Perl code (using Perl::PrereqScanner) and what's in Perl core list of
modules. Will complain if your prerequisites are not actually used, or already
in Perl core. Will also complain if there are missing prerequisites.

Designed to work with prerequisites that are manually written. Does not work if
you use AutoPrereqs.

Sometimes there are prerequisites that you know are used but can't be detected
by scan_prereqs, or you want to include anyway. If this is the case, you can
instruct lint_prereqs to assume the prerequisite is used.

 ;!lint-prereqs assume-used # even though we know it is not currently used
 Foo::Bar=0
 ;!lint-prereqs assume-used # we are forcing a certain version
 Baz=0.12

Sometimes there are also prerequisites that are detected by scan_prereqs, but
you know are already provided by some other modules. So to make lint-prereqs
ignore them:

 [Extras / lint-prereqs / assume-provided]
 Qux::Quux=0

Arguments ('*' denotes required arguments):

=over 4

=item * B<perl_version> => I<str>

Perl version to use (overrides scan_prereqs/dist.ini).

=back

Return value:

Returns an enveloped result (an array).

First element (status) is an integer containing HTTP status code
(200 means OK, 4xx caller error, 5xx function error). Second element
(msg) is a string containing error message, or 'OK' if status is
200. Third element (result) is optional, the actual result. Fourth
element (meta) is called result metadata and is optional, a hash
that contains extra information.

 (any)

=head1 HOMEPAGE

Please visit the project's homepage at L<https://metacpan.org/release/App-LintPrereqs>.

=head1 SOURCE

Source repository is at L<https://github.com/perlancar/perl-App-LintPrereqs>.

=head1 BUGS

Please report any bugs or feature requests on the bugtracker website L<https://rt.cpan.org/Public/Dist/Display.html?Name=App-LintPrereqs>

When submitting a bug or request, please include a test-file or a
patch to an existing test-file that illustrates the bug or desired
feature.

=head1 AUTHOR

perlancar <perlancar@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2014 by perlancar@cpan.org.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
