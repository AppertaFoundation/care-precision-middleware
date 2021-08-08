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

my $assessment = decode_json(curfile->dirname->child('etc/denwis.json')->slurp);
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

my @assessments = $utils->assessments_from_xml($compositions->[0]);

use Data::Dumper; print Dumper \@assessments;
