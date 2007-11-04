#!/usr/bin/perl
# $Id$

use strict;
use File::Basename;
use File::Path;
use File::Temp qw/tempdir/;
use Test::More tests => 6;
use Test::Exception;
use RPM4;

BEGIN {
    use_ok('Youri::Package::RPM::Builder');
}

my $source = dirname($0) . '/perl-File-HomeDir-0.58-1mdv2007.0.src.rpm';

my $topdir = tempdir(cleanup => 1);
foreach my $dir qw/BUILD SPECS SOURCES SRPMS RPMS tmp/ {
    mkpath(["$topdir/$dir"]);
};
foreach my $arch qw/noarch/ {
    mkpath(["$topdir/RPMS/$arch"]);
};

RPM4::setverbosity(0);
RPM4::add_macro("_topdir $topdir");
my ($spec_file) = RPM4::installsrpm($source);

my $builder = Youri::Package::RPM::Builder->new(
    topdir => $topdir,
    options => '>/dev/null 2>&1'
);
isa_ok($builder, 'Youri::Package::RPM::Builder');

lives_ok {
    $builder->build($spec_file);
} 'building';

my @binaries = <$topdir/RPMS/noarch/*.rpm>;
is(scalar @binaries, 1, 'one binary package');
my @sources = <$topdir/SRPMS/*.rpm>;
is(scalar @sources, 1, 'one source package');

my $package = RPM4::Header->new($sources[0]);
isa_ok($package, 'RPM4::Header');
