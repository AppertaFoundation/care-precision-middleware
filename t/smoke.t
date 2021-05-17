#!perl

use v5.28;
use Test::More;
use Test::Mojo;
use Mojo::File qw(curfile);
use Data::Dumper;

$ENV{FRONTEND_HOSTNAME} = 'localhost';

my $app = Test::Mojo->new(curfile->dirname->sibling('app/careprotect.pl'));

my $app = $app->get_ok('/c19-alpha/0.0.1/meta/demographics/patient_list')
            ->json_is('/0/name' => 'Mrs Elsie Mills-Samson', "Expected first patient is first");

            #print Dumper $app->tx->res->json;

done_testing;
