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
