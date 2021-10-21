#!perl

# Internal perl (move to 5.32.0)
use v5.30.0;

# Internal perl modules (core)
use strict;
use warnings;
use utf8;
use experimental qw(signatures);

# Remove warnings for deep recursion
no warnings 'recursion';

# Internal modules (debug)
use Data::Dumper;
use Carp;

# Additional modules
use XML::DOM;
use IO::File;
use JSON::MaybeXS;
use File::Slurp;
use Data::Tree::Describe;

exit do { main() };

sub main {
    # Read in the submitted json
    my $composition_json            =
        decode_json(read_file('composition.json'));

    # Read in the template XML
    my $xml_parser                  =
        new XML::DOM::Parser;

    my $xml_composition             =
        $xml_parser->parsefile('composition.xml');

    # Create a map of paths for the JSON object
    my $composition_json_pathing    =
        Data::Tree::Describe->new($composition_json);

    # Collect a list of absolute element paths 
    my @json_paths                  =
        $composition_json_pathing->paths_list();

    # my $node = $xml_composition->getElementsByTagName ('template_id');
    # say $node->[0]->toString;

    foreach my $json_element ($composition_json_pathing->paths_list) {
        $xml_composition =
            matrix_conversion(
                $composition_json,
                $json_element,
                $xml_composition
            );
    }
}



sub matrix_conversion (
    $json_object,
    $json_node,
    $xml_object
)   {
    say $json_node->type;
    #say "processing: ".join('->',@{$json_path});
    #my $node = $json_path->type;
}


# sub xml_action($writer,$name,$action,$args = {}) {

#     # Begin creating the XML document
#     my $writerx = XML::Writer->new( OUTPUT => 'self', ENCODING => 'utf-8', DATA_INDENT => " "x4, DATA_MODE => 1);
#     $writer->xmlDecl('UTF-8','yes');

#     # Composition Tag
#     $writer = xml_action(
#         $writer,
#         'composition',
#         'open',
#         {
#             'xmlns'             =>  'http://schemas.openehr.org/v1',
#             'archetype_node_id' =>  'openEHR-EHR-COMPOSITION.encounter.v1'
#         }
#     );

#     $writer = xml_action(
#         $writer,
#         'name',
#         'open'
#     );

#     $writer = xml_action(
#         $writer,
#         'value',
#         'open'
#     );

#     $writer = xml_action(
#         $writer,
#         'characters',
#         'characters',
#         {
#             data    =>  'open_eREACT-Care'
#         }
#     );

#     $writer = xml_action(
#         $writer,
#         'value',
#         'close'
#     );

#     $writer = xml_action(
#         $writer,
#         'name',
#         'close'
#     );

#     $writer = xml_action(
#         $writer,
#         'uid',
#         'open',
#         {
#             'xmlns:xsi' =>  "http://www.w3.org/2001/XMLSchema-instance",
#             'xsi:type'  =>  "OBJECT_VERSION_ID"
#         }
#     );

#     $writer = xml_action(
#         $writer,
#         'value',
#         'open'
#     );

#     $writer = xml_action(
#         $writer,
#         'characters',
#         'characters',
#         {
#             data    =>  '58e35672-e17a-44e4-90c1-682637cd8e23::a81f47c6-a757-4e34-b644-3ccc62b4a01c::1'
#         }
#     );

#     $writer = xml_action(
#         $writer,
#         'value',
#         'close'
#     );

#     say $writer->to_string;

#     if      ($action eq 'open')     {
#         $writer->startTag($name,%$args);
#     }
#     elsif   ($action eq 'close')    {
#         $writer->endTag($name);
#     }
#     elsif   ($action eq 'characters')    {
#         $writer->characters($args->{data});
#     }
#     else {
#         die "No such action: '$action'";
#     }
#     return $writer;
# }
