# $Id$

package Youri::Package::RPM::Builder;

=head1 NAME

Youri::Package::RPM::Builder - Build RPM packages

=head1 SYNOPSIS

    my $builder = Youri::Package::RPM::Builder->new();
    $builder->build('foo');

=head1 DESCRIPTION

This module builds rpm packages.

=cut

use strict;
use Carp;
use RPM4;
use String::ShellQuote;
use version; our $VERSION = qv('0.1.0');

=head1 CLASS METHODS

=head2 new(%options)

Creates and returns a new Youri::Package::RPM::Builder object.

Avaiable options:

=over

=item verbose $level

verbosity level (default: 0).

=item topdir $topdir

rpm top-level directory (default: rpm %_topdir macro).

=item sourcedir $sourcedir

rpm source directory (default: rpm %_sourcedir macro).

=item options $options

rpm build options.

=item build_source true/false

build source package (default: true).

=item build_binaries true/false

build binary packages (default: true).

=item build_requires_callback $callback

callback to execute before build, with build dependencies as argument (default:
none).

=item build_requires_command $command

external command (or list of commands) to execute before build, with build
dependencies as argument (default: none). Takes precedence over previous option.

=item build_results_callback $callback

callback to execute after build, with build packages as argument (default:
none).

=item build_results_command $command

external command (or list of commands) to execute after build, with build packages as argument (default: none). Takes precedence over previous option.

=back

=cut

sub new {
    my ($class, %options) = @_;

    if ($options{build_requires_command}) {
        $options{build_requires_callback} = sub {
            foreach my $command (
                ref $options{build_requires_command} eq 'ARRAY' ?
                    @{$options{build_requires_command}} :
                    $options{build_requires_command}
            ) {
                # we can't use multiple args version of system here, as we
                # can't assume given command is just a program name,
                # as in 'sudo rurpmi' case
                system($command . ' ' . shell_quote(@_));
            }
        }
    }

    if ($options{build_results_command}) {
        $options{build_results_callback} = sub {
            foreach my $command (
                ref $options{build_results_command} eq 'ARRAY' ?
                    @{$options{build_results_command}} :
                    $options{build_results_command}
            ) {
                # same issue here
                system($command . ' ' . shell_quote(@_));
            }
        }
    }

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

    my $self = bless {
        _topdir                  => $topdir,
        _sourcedir               => $sourcedir,
        _verbose                 => $options{verbose}                 || 0,
        _build_source            => $options{build_source}            || 1,
        _build_binaries          => $options{build_binaries}          || 1,
        _build_requires_callback => $options{build_requires_callback} || undef,
        _build_results_callback  => $options{build_results_callback}  || undef,
    }, $class;

    return $self;
}

=head1 INSTANCE METHODS

=head2 build($spec_file, %options)

=cut

sub build {
    my ($self, $spec_file, %options) = @_;
    croak "Not a class method" unless ref $self;

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
    if ($self->{_build_source} && $self->{_build_binaries}) {
        $command .= " -ba $self->{_options} $spec_file";
        push(@dirs, qw/rpmdir srcrpmdir/);
    } elsif ($self->{_build_binaries}) {
        $command .= " -bb $self->{_options} $spec_file";
        push(@dirs, qw/rpmdir/);
    } elsif ($self->{_build_source}) {
        $command .= " -bs $self->{_options} --nodeps $spec_file";
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
