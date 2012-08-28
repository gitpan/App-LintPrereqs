package App::LintPrereqs;

use 5.010;
use strict;
use warnings;
use Log::Any qw($log);

use Config::IniFiles;
use File::Find;
use File::Which;
use Sort::Versions;

our %SPEC;
require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(lint_prereqs);

our $VERSION = '0.06'; # VERSION

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
        default_perl_version => {
            schema => [str => {default=>'5.010000'}],
            summary => 'Perl version to use when unspecified',
        },
    },
};
sub lint_prereqs {
    my %args = @_;

    (-f "dist.ini")
        or return [412, "No dist.ini found, ".
                       "is your dist managed by Dist::Zilla?"];

    my $cfg = Config::IniFiles->new(-file => "dist.ini", -fallback => "ALL");
    $cfg or return [
        500, "Can't open dist.ini: ".join(", ", @Config::IniFiles::errors)];

    my %mods_from_ini;
    my %assume_used;
    my %assume_provided;
    for my $section (grep {
        m!^(prereqs|extras \s*/\s* lint[_-]prereqs \s*/\s*
              assume-(?:provided|used))!ix}
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
            $pkg =~ s!^lib/!!;
            $pkg =~ s!/!::!g;
            $pkg .= "::$_";
            $pkg =~ s/\.pm$//;
            $pkgs{$pkg}++;
        },
    }, "lib");
    $log->tracef("Packages: %s", \%pkgs);

    my %mods_from_scanned;
    my $sppath = which("scan_prereqs")
        or return [412, "Can't find scan_prereqs in PATH"];
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

    my $perlv = $mods_from_ini{perl} // $mods_from_scanned{perl} // '5.010000';

    my %core_mods;
    my $clpath = which("corelist")
        or return [412, "Can't find corelist in PATH"];
    for (`$clpath -v $perlv`) {
        chomp;
        /^([\w:]+)(?:\s+(\S+))?\s*$/ or next;
        #do {
        #    warn "Invalid line from $clpath: $_, skipped";
        #    next;
        #};
        $core_mods{$1} = $2 // 0;
    }

    my @errs;
    for my $mod (keys %mods_from_ini) {
        next if $mod eq 'perl';
        $log->tracef("Checking mod from dist.ini: %s", $mod);
        if (exists($core_mods{$mod}) &&
                versioncmp($core_mods{$mod}, $mods_from_ini{$mod}) >= 0) {
            push @errs, {
                module=>$mod, message=>"Core but mentioned"};
        }
        unless (exists($mods_from_scanned{$mod}) ||
                    exists($assume_used{$mod})) {
            push @errs, {
                module  => $mod,
                message => "Unused but listed in dist.ini"};
        }
    }

    for my $mod (keys %mods_from_scanned) {
        next if $mod eq 'perl';
        $log->tracef("Checking mod from scanned: %s", $mod);
        next if exists $core_mods{$mod}; # XXX check version
        next if exists $pkgs{$mod};
        unless (exists($mods_from_ini{$mod}) ||
                    exists($assume_provided{$mod})) {
            push @errs, {
                module  => $mod,
                message => "Used but not listed in dist.ini"};
        }
    }

    [200, @errs ? "Extraneous/missing dependencies" : "OK", \@errs,
     {"cmdline.exit_code" => @errs ? 200:0}];
}

1;
#ABSTRACT: Check extraneous/missing prerequisites in dist.ini


__END__
=pod

=head1 NAME

App::LintPrereqs - Check extraneous/missing prerequisites in dist.ini

=head1 VERSION

version 0.06

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
by scanB<prereqs, or you want to include anyway. If this is the case, you can
instruct lint>prereqs to assume the prerequisite is used.

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

=item * B<default_perl_version> => I<str> (default: "5.010000")

Perl version to use when unspecified.

=back

Return value:

Returns an enveloped result (an array). First element (status) is an integer containing HTTP status code (200 means OK, 4xx caller error, 5xx function error). Second element (msg) is a string containing error message, or 'OK' if status is 200. Third element (result) is optional, the actual result. Fourth element (meta) is called result metadata and is optional, a hash that contains extra information.

=head1 AUTHOR

Steven Haryanto <stevenharyanto@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2012 by Steven Haryanto.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
