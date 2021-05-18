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
my $patients = $app->get_ok('/c19-alpha/0.0.1/meta/demographics/patient_list')
    ->status_is(200)
    ->json_is('/0/name' => 'Mrs Elsie Mills-Samson', "Expected first patient is first")
    ->tx->res->json;

# Read in the template denwis json
my $denwis = decode_json(curfile->dirname->child('etc/denwis.json')->slurp);
$denwis->{header}->{uuid} = $patients->[0]->{uuid};

# Post the resultant created composition to the middleware
$app->post_ok('/c19-alpha/0.0.1/cdr' => json => $denwis)
    ->status_is(204);

my $news2 = decode_json(curfile->dirname->child('etc/news2-minimum-fields.json')->slurp);
$news2->{header}->{uuid} = $patients->[1]->{uuid};

my $news2_draft = $app->post_ok('/c19-alpha/0.0.1/cdr/draft' => json => $news2)
    ->status_is(200)
    ->tx->res->json;

$news2->{assessment}->{news2}->{news2_score} = $news2_draft->{news2}->{score};

$app->post_ok('/c19-alpha/0.0.1/cdr' => json => $news2)
    ->status_is(204);

$app->get_ok('/c19-alpha/0.0.1/meta/demographics/patient_list?search_key=uuid&search_value=' . $patients->[0]->{uuid})
    ->json_has('/0/assessment/denwis')
    ->json_has('/1/assessment/news2')
    ->tx->res->json;

done_testing;
