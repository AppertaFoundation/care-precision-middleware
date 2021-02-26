use warnings; 
use strict; 
use Encode qw(is_utf8 encode decode); 
use feature 'say';

use LWP::UserAgent;
use HTTP::Request;
use DateTime;
use URI;
use URI::QueryParam;
use HTTP::Request::Common;

use Template;
use JSON::Pointer;

use Data::UUID;

#my $c = do { 
#    local $/,
#    open(my $fh,"<","composition-news2-finished.xml");
#    my $x=<$fh>;
#    close($fh);
#    $x 
#}; 

my $json_in = do {
    local $/;
    open(my $fh,'<','patients.json');
    my $input = <$fh>;
    close($fh);
    $input
};
         
my $req_url = 'http://ehrbase.c19.devmode.xyz/ehrbase/rest/openehr/v1/ehr/d4ac93a7-4380-46a6-9cb3-49915381a94a/composition';
my $passed_objects = {};
            #my $patient_uuid = $passed_objects->[1]->{situation}->{uuid};

            # Create a place to put everything we need for ease and clarity
            my $uuid = $uuid->to_string($uuid->create());
            my $composition_obj =   {
                uuid    =>  $uuid,
                #base    =>  join('',read_file('composition.xml')),
                input   =>  $passed_objects
            };


my $xml_transformation = sub {
    my $big_href = shift;
    my $tt2 = Template->new({ ENCODING => 'utf8' });

    $big_href->[1]->{header}->{start_time} = DateTime->now->strftime('%Y-%m-%dT%H:%M:%SZ');

    my $json_path = sub { JSON::Pointer->get($big_href, $_[0]) };

    my $output;
    $tt2->process('template.xml', { json_path => $json_path },\$output );
    return $output;
};

my $c = $xml_transformation->($json_in);

            my $request = POST($req_url);
            $request->header('Accept' => '*/*');
            $request->header('Content-Type' => 'application/xml');
            $request->content($c);

            my $ua = LWP::UserAgent->new();
            my $res = $ua->request($request);
            warn $res->code();
