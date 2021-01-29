#!/usr/bin/env perl

# Internal perl version
use v5.26.0;

# Internal perl modules (core)
use utf8;
use strict;
use warnings 
    FATAL => 'uninitialized';
use experimental
    qw(signatures);
no indirect;

# Internal perl modules (debug)  
use Data::Dumper;
use Carp
    qw( cluck longmess shortmess );

# Configure carp to trigger on die
$SIG{__DIE__} = 
    \&Carp::confess;

# Core perl modules (extended datastructure tools)
use List::Util
    qw( reduce any all none notall first max maxstr min 
        minstr product sum sum0 pairs unpairs pairkeys pairvalues 
        pairfirst pairgrep pairmap shuffle uniq uniqnum );
use Scalar::Util
    qw( blessed dualvar isdual readonly refaddr reftype
        tainted weaken isweak isvstring looks_like_number
        set_prototype );
use Hash::Util
    qw( fieldhash fieldhashes all_keys );

# Core perl modules (extended filesystem tools)
use Cwd ();
use FindBin ();
use File::Path ();
use File::Temp ();
use File::Spec ();

# Core perl modules (multiprocess and pipe support)
use IPC::Cmd ();

# Core perl modules (extended encoding)
use Encode qw(encode_utf8);
use Digest ();
use MIME::QuotedPrint ();
use MIME::Base64 qw(encode_base64 decode_base64);

# Core perl modules (extended math functions)
use Math::BigInt ();

# Core perl modules (enviromental)
use Getopt::Long ();
use Module::Load ();
use Env ();

use Template;
use Data::UUID;
use Path::Tiny;
use JSON::Pointer;
use JSON::MaybeXS;

# User option initilization
my $getopt =    Getopt::Long::Parser->new;

# Entrypoint, will exit with the return of main
exit do { main(\%ENV,\@ARGV) || 0 };

sub main($env,$argv) 
{
    my ($inxml,$outxml);

    my $stash   =   {};
    my $uuid    =   Data::UUID->new;

    $getopt->getoptionsfromarray(
        $argv,
        "in=s"      =>  \$inxml,
        "out=s"     =>  \$outxml
    ) or do {
        say STDERR "Error: $?";
        exit 1;
    };

    my $composition_obj = decode_json(do { local $/; <> });

    my $xml_transformation = sub {
        my $big_href = shift;
        my $tt2 = Template->new();

        my $json_path = sub { JSON::Pointer->get($big_href, $_[0]) };

        $tt2->process($inxml, { json_path => $json_path }, \my $out) || die $tt2->error;
        $out;
    };

    my $output = $xml_transformation->($composition_obj);

    path($outxml)->spew_utf8($output);
}
