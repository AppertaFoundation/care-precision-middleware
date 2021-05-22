#!perl

use v5.28;
use Test::More;
use Test::Mojo;
use Mojo::File qw(curfile);
use Mojo::JSON qw(decode_json);
use Data::Dumper;

$ENV{FRONTEND_HOSTNAME} = 'localhost';

my $app = Test::Mojo->new(curfile->dirname->sibling('app/careprotect.pl'));

# Retrieve the patient list and check for the presence of Elsie Mills-Samson
my $patients = $app->get_ok('/v1/patients')
    ->status_is(200)
    ->tx->res->json;

$app->get_ok('/v1/patient/' . $patients->[0]->{uuid})
    ->status_is(200)
    ->json_is('' => $patients->[0], "Returns the single patient expected");

# Read in the template denwis json
my $denwis = decode_json(curfile->dirname->child('etc/denwis.json')->slurp);

# Post the resultant created composition to the middleware
$app->post_ok('/v1/patient/' . $patients->[0]->{uuid} . '/cdr' => json => $denwis, "Posting DENWIS object")
    ->status_is(204, "DENWIS posted OK")
    ->or(sub { diag Dumper $app->tx->res->json });

my $news2 = decode_json(curfile->dirname->child('etc/news2-minimum-fields.json')->slurp);

my $news2_draft = $app->post_ok('/v1/patient/' . $patients->[2]->{uuid} . '/cdr/draft' => json => $news2)
    ->status_is(200, "NEWS2 draft posted OK")
    ->json_has('/news2/score')
    ->or(sub { diag Dumper $app->tx->res->json });

$app->post_ok('/v1/patient/' . $patients->[1]->{uuid} . '/cdr' => json => $news2)
    ->status_is(204, "NEWS2 posted OK")
    ->or(sub { diag Dumper $app->tx->res->json });

# There are three shapes of covid data but I can't remember why so I'm just
# doing one of them to check it works
my $covid = decode_json(curfile->dirname->child('etc/covid-a.json')->slurp);

$app->post_ok('/v1/patient/' . $patients->[2]->{uuid} . '/cdr' => json => $covid)
    ->status_is(204, "COVID posted OK")
    ->or(sub { diag Dumper $app->tx->res->json });

$app->get_ok('/v1/patients')
    ->json_has('/0/assessment/denwis')
    ->json_has('/1/assessment/news2')
    ->json_has('/2/assessment/covid')
    ->or(sub { diag Dumper $app->tx->res->json });

done_testing;
