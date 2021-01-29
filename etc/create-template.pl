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

# User modules
use XML::TreeBuilder;
use HTML::TreeBuilder::LibXML;
use Template::Toolkit;
use Data::UUID;
use Path::Tiny;
use HTML::FormatText;

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

    # Convert the XML into a TreeBuilder::XML object
    my $tree = parse_xml_in($inxml);

    # Pass 1 - Search down for all elements that have no descendants
    foreach my $element (find_child_less_children($tree)) {
        # Create a unique anchor as a uuid
        my $store_uuid =
            $uuid->to_string($uuid->create());

        # Store the original value against the uuid
        $stash->{anchors}->{$store_uuid}->{value}   =
            encode_base64(encode_utf8($element->as_trimmed_text),'');

        # Find the path to the node
        $stash->{anchors}->{$store_uuid}->{path}    =
            extrapolate_xml_path($element);

        # Replace the original content with the anchor
        $element->delete_content;
        $element->push_content($store_uuid);
    }

    # Save the updated XML to the stash, destroy the original
    $stash->{stage1_xml} = 
        $tree->as_XML;
    $tree->delete;

    # Stage 2 - Replace the anchors with a TT compatible term
    if (my $stage2_xml = $stash->{stage1_xml}) {
        foreach my $anchor_key (keys %{$stash->{anchors}})
        {
            my $anchor_value    =
                $stash->{anchors}->{$anchor_key}->{value};
            my $path            =
                $stash->{anchors}->{$anchor_key}->{path};
            ($stage2_xml) =~ s/$anchor_key/generate_tt_anchor($anchor_key,$anchor_value,$path)/e;
        }

        $stash->{stage2_xml} = $stage2_xml;
    }

    # Stage 3 - handled externally use tt to render the transmogrify subroutines


    # Finish (write the out file)
    path($outxml)->spew_utf8($stash->{stage2_xml});
}

sub parse_xml_in($file_in)
{
    if (!$file_in || !-e $file_in)
    {
        say STDERR "Invalid input file specified";
        exit 1;
    }

    my $raw_xml     =
        path($file_in)->slurp_utf8;
    my $xml_tree    =
        XML::TreeBuilder->new({ 'NoExpand' => 0, 'ErrorContext' => 0 });
    $xml_tree       ->
        parse($raw_xml);
    $xml_tree->eof;

    return $xml_tree;
}

# Look down from a position within the XML tree for all children with no 
# no decesendants
sub find_child_less_children ($tree)
{
    my @elements = $tree->look_down(sub { $_[0]->descendants == 0 });
    return @elements;
}

sub generate_tt_anchor($anchor_uuid,$anchor_value,$path)
{
    my $path_as_text    =
        join('/',@{$path});
    return "[% transmogrify('$anchor_value','$path_as_text') %]";
}

sub extrapolate_xml_path($element) 
{
    my @path = ();
    push @path,$element->tag;
    until (not($element->parent))
    {
        $element = $element->parent;
        push @path,$element->tag;
    }
    @path = reverse @path;
    return \@path;
}