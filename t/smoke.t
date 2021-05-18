#!perl

use v5.28;
use Test::More;
use Test::Mojo;
use Mojo::File qw(curfile);
use Mojo::JSON qw(decode_json);
use Data::Dumper;

$ENV{FRONTEND_HOSTNAME} = 'localhost';

my $app = Test::Mojo->new(curfile->dirname->sibling('app/careprotect.pl'));

my $patients = $app->get_ok('/c19-alpha/0.0.1/meta/demographics/patient_list')
    ->status_is(200)
    ->json_is('/0/name' => 'Mrs Elsie Mills-Samson', "Expected first patient is first")
    ->tx->res->json;

my $denwis = decode_json(curfile->dirname->child('etc/denwis.json')->slurp);
$denwis->{header}->{uuid} = $patients->[0]->{uuid};

$app->post_ok('/c19-alpha/0.0.1/cdr' => json => $denwis)
    ->status_is(204);

print Dumper $app->get_ok('/c19-alpha/0.0.1/meta/demographics/patient_list?search_key=uuid&search_value=' . $patients->[0]->{uuid})
    ->json_has('/0/assessment/denwis')->tx->res->json;

done_testing;
