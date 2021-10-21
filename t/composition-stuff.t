#!perl

use lib 't/lib';

use v5.28;
use Mojo::File qw(curfile);
use Mojo::JSON qw(decode_json);
use Utils;
use DBHelper;
use DateTime;

my $dbh = DBHelper->new( curfile->dirname->sibling('var'), 1 );

my $utils = Utils->new(
    template_path => curfile->dirname->sibling('etc'),
    dbh => $dbh,
);

my $denwis = decode_json(curfile->dirname->child('etc/denwis.json')->slurp);
my $news2 = decode_json(curfile->dirname->child('etc/news2-minimum-fields.json')->slurp);
my $covid = decode_json(curfile->dirname->child('etc/covid-a.json')->slurp);

my $assessment = {
    %$denwis, %$covid, %$news2
};

$utils->fill_in_scores($assessment);

my $composition = {
    assessment => $assessment,
    header     => {
        start_time => DateTime->now->strftime('%Y-%m-%dT%H:%M:%SZ'),
        composer => {
            name => "Login McUserdata"
        },
        healthcare_facility => "Glen Carse Care Home"
    }
};


my $xml_composition = $utils->composition_to_xml($composition);

my $all_patients = $dbh->find_patients({});

my $patient_uuid = $all_patients->[0]->{uuid};

$utils->store_composition($patient_uuid, $xml_composition);

my $compositions = $utils->{ehr_helper}->get_compositions($patient_uuid);

# Just don't crash - don't need return val
$utils->assessments_from_xml($compositions->[0]);

my $composed = $utils->compose_assessments( $patient_uuid );

my $summarised = $utils->summarise_composed_assessment( $composed );

use Data::Dumper; print Dumper $xml_composition;
