# $Id$

package Youri::Package::RPM::Builder;

=head1 NAME

Youri::Package::RPM::Builder - Build RPM packages

=head1 SYNOPSIS

    my $builder = Youri::Package::RPM::Builder->new();
    $builder->build('foo');

=head1 DESCRIPTION

This module builds rpm packages.

=head1 CONFIGURATION

The system configuration file for this module is
@sysconfdir@/youri/builder.conf. The user configuration file is
$HOME/.youri/builder.conf. The last one has precedence on the first one.

=over

=cut

use strict;
use Carp;
use POSIX qw(setlocale LC_ALL);
use RPM4;
use String::ShellQuote;
use version; our $VERSION = qv('0.1.1');

# we rely on parsing rpm errors strings, so we have to ensure locale neutrality
setlocale( LC_ALL, "C" );

=head1 CLASS METHODS

=head2 new(%options)

Creates and returns a new Youri::Package::RPM::Builder object.

Available options:

=over

=item verbose $level

verbosity level (default: 0).

=item topdir $topdir

rpm top-level directory (default: rpm %_topdir macro).

=item sourcedir $sourcedir

rpm source directory (default: rpm %_sourcedir macro).


=back

=cut

sub new {
    my ($class, %options) = @_;

    # force internal rpmlib configuration
    my ($topdir, $sourcedir);
    if ($options{topdir}) {
        $topdir = File::Spec->rel2abs($options{topdir});
        RPM4::add_macro("_topdir $topdir");
    } else {
        $topdir = RPM4::expand('%_topdir');
    }
    if ($options{sourcedir}) {
        $sourcedir = File::Spec->rel2abs($options{sourcedir});
        RPM4::add_macro("_sourcedir $sourcedir");
    } else {
        $sourcedir = RPM4::expand('%_sourcedir');
    }

    my $config = Youri::Config->new(
        directories => [ '@sysconfdir@/youri', "$ENV{HOME}/.youri"  ],
        file => 'builder.conf',
    );

    my $build_requires_command = $config->get_param('build_requires_command');
    my $build_requires_callback;
    if ($build_requires_command) {
        $build_requires_callback = sub {
            foreach my $command (
                ref $build_requires_command eq 'ARRAY' ?
                    @{$build_requires_command} :
                    $build_requires_command
            ) {
                # we can't use multiple args version of system here, as we
                # can't assume given command is just a program name,
                # as in 'sudo rurpmi' case
                my $result = system($command . ' ' . shell_quote(@_));
                croak("Error while executing build requires command: $?\n")
                    if $result != 0;
            }
        }
    }

    my $build_results_command = $config->get_param('build_result_command');
    my $build_results_callback;
    if ($build_results_command) {
        $build_results_callback = sub {
            foreach my $command (
                ref $build_results_command eq 'ARRAY' ?
                    @{$build_results_command} :
                    $build_results_command
            ) {
                # same issue here
                my $result = system($command . ' ' . shell_quote(@_));
                croak("Error while executing build results command: $?\n")
                    if $result != 0;
            }
        }
    }

    my $self = bless {
        _config                  => $config,
        _topdir                  => $topdir,
        _sourcedir               => $sourcedir,
        _verbose                 => defined $options{verbose}        ?
            $options{verbose}        : 0,
        _build_requires_callback => defined $build_requires_callback ?
            $build_requires_callback : undef,
        _build_results_callback  => defined $build_results_callback  ?
            $build_results_callback  : undef,
    }, $class;

    return $self;
}

=head1 INSTANCE METHODS

=head2 build($spec_file, %options)

Available options:

=over

=item rpm_options $options

rpm build options.

=item build_source true/false

build source package (default: true).

=item build_binaries true/false

build binary packages (default: true).

=back

=cut

sub build {
    my ($self, $spec_file, %options) = @_;
    croak "Not a class method" unless ref $self;

    $options{build_binaries}  = 1  unless defined $options{build_binaries};
    $options{build_source}    = 1  unless defined $options{build_source};
    $options{rpm_options}     = "" unless defined $options{rpm_options};

    my $spec = RPM4::Spec->new($spec_file, force => 1)
        or croak "Unable to parse spec $spec_file\n";
    my $header = $spec->srcheader();

    if ($self->{_build_requires_callback}) {
        print "managing build dependencies\n"
            if $self->{_verbose};

        my $db = RPM4::Transaction->new();
        $db->transadd($header, "", 0);
        $db->transcheck();
        my $pbs = $db->transpbs();
 
        if ($pbs) {
            my @requires;
            $pbs->init();
            while($pbs->hasnext()) {
                my ($require) = $pbs->problem() =~ /^
                    (\S+) \s              # dependency
                    (?:\S+ \s \S+ \s)?    # version
                    is \s needed \s by \s # problem
                    \S+                   # source package
                    $/x;
                next unless $require;
                push(@requires, $require);
            }
            $self->{_build_requires_callback}->(@requires);
        }
    }

    my $command = "rpm";
    $command .= " --define '_topdir $self->{_topdir}'";
    $command .= " --define '_sourcedir $self->{_sourcedir}'";

    my @dirs = qw/builddir/;
    if ($options{build_source} && $options{build_binaries}) {
        $command .= " -ba $options{rpm_options} $spec_file";
        push(@dirs, qw/rpmdir srcrpmdir/);
    } elsif ($options{build_binaries}) {
        $command .= " -bb $options{rpm_options} $spec_file";
        push(@dirs, qw/rpmdir/);
    } elsif ($options{build_source}) {
        $command .= " -bs $options{rpm_options} --nodeps $spec_file";
        push(@dirs, qw/srcrpmdir/);
    }
    $command .= " >/dev/null 2>&1" unless $self->{_verbose} > 1;

    # check needed directories exist
    foreach my $dir (map { RPM4::expand("\%_$_") } @dirs) {
        next if -d $dir;
        mkdir $dir or croak "Can't create directory $dir: $!\n";
    }

    my $result = system($command) ? 1 : 0;
    croak("Build error\n")
        unless $result == 0;

    if ($self->{_build_results_callback}) {
        my @results =
            grep { -f $_ }
            $spec->srcrpm(),
            $spec->binrpm();
        print "managing build results : @results\n"
            if $self->{_verbose};
        $self->{_build_results_callback}->(@results)
    }
}

1;
