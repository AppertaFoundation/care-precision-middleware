#!/usr/bin/env perl
use Mojolicious::Lite -signatures;

use lib 'lib';
use Utils;
use EHRHelper;
use DBHelper;

use Data::UUID;
use DateTime;
use Encode;
use File::Temp qw(tempfile);
use JSON::Pointer;
use List::Gather;
use Mojo::UserAgent;
use Template;
use Try::Tiny;

use Data::Dumper;

my $api_prefix              =   '/c19-alpha/0.0.1';

# Load JSON / UUID mnodules
my $uuid                    =   Data::UUID->new;
my $json                    =   JSON::MaybeXS->new(utf8 => 1)->allow_nonref(1);
my $dbh                     =   DBHelper->new(1);

plugin "OAuth2" => {
    opus => {
        # FIXME : secret should NOT be hard coded!
        key    => 'open-ereact-poc',
        secret => '3debdc8d-c478-4747-b21e-046b044e2c03',
        token_url => 'https://sso.opusvl.com/auth/realms/opusvl/protocol/openid-connect/token',
        authorize_url => 'https://sso.opusvl.com/auth/realms/opusvl/protocol/openid-connect/auth?response_type=code',
    },
    mocked => { key => 42 }
};

# TODO - TAG:waresf do we need these twice?
plugin "SecureCORS" => {
    'cors.origin' => '*',
    'cors.headers' => 'Content-Type',
    'cors.credentials' => 1,
    'cors.methods' => 'GET,POST,PUT,DELETE'
};

helper search => sub ($c, $search_spec) {
    my $search_result   =   [];

    # Filter

    # Sort
    if ($search_spec->{sort}->{enabled}) {
        foreach my $uuid_return ( $dbh->return_col_sorted('uuid',$search_spec->{sort})->@* ) {
            my $userid  =
                $uuid_return->[0];

            my $search_db_ref   =   $dbh->return_row(
                'uuid',
                $userid
            );

            push @{$search_result},$search_db_ref;
        }
    }
    else {
        foreach my $uuid_return ( $dbh->return_col('uuid')->@* ) {
            my $userid  =
                $uuid_return->[0];

            my $search_db_ref   =   $dbh->return_row(
                'uuid',
                $userid
            );

            push @{$search_result},$search_db_ref;
        }
    }

    # Search - should be restricted to what is already in search_result!
    # at present will basically ignore sort and only return one item
    if ($search_spec->{search}->{enabled}) {
        # Frontend sends id, when it should send uuid
        $search_spec->{search}->{key} = 'uuid'
            if $search_spec->{search}->{key} eq 'id';

        my $search_key = $search_spec->{search}->{key};

        my $search_value = $search_spec->{search}->{value};

        my $search_match = $dbh->search_match($search_key,$search_value);

        if ($search_match) {
            my $search_db_ref   =   $dbh->return_row(
                'uuid',
                $search_match
            );

            push @{$search_result},$search_db_ref;
        }
    }

    if (@$search_result) {
        say STDERR "Compatability function in use for birth_date, at line: ".__LINE__;
        map {
            $_->{birthDate} = $_->{birth_date}; 
            $_->{birthDateAsString} = $_->{birth_date_string};
            $_->{id} = $_->{uuid}
        } @{$search_result};
    }

    # If no pagination just return whatever survived the run
    return $search_result;
};

under $api_prefix;

get '/' => sub ($c) {
    $c->render(template => 'index');
};

get '/_/auth' => sub ($c) {
    my $get_token_args = {
        redirect_uri => $c->url_for("/c19-alpha/0.0.1/_/auth")->userinfo(undef)->to_abs
    };

    $c->oauth2->get_token_p(opus => $get_token_args)->then(sub {
        return unless my $provider_res = shift;
        $c->session(token => $provider_res->{access_token});
        $c->redirect_to("/");
    })->catch(sub {
        $c->render("connect", error => shift);
    });
};

get '/meta/demographics/patient_list' => sub ($c) {
    my $params = $c->req->query_params;
    my $search_spec = {
        gather {
            if ($params->{search_key} and $params->{search_value}) {
                take (
                    search => {
                        key   => $params->{'search_key'},
                        value => $params->{'search_value'}
                    },
                )
            }

            if ($params->{sort_key} and $params->{sort_value}) {
                take (
                    sort => {
                        key   => $params->{'sort_key'},
                        value => $params->{'sort_value'}
                    },
                )
            }
        }
    };

    # Add in fast checks
    foreach my $key (keys %{$search_spec}) {
        my $valid_check = do {
            my $values_valid = 1;
            foreach my $subkey (keys %{$search_spec->{$key}}) {
                if (!defined $search_spec->{$key}->{$subkey}) {
                    $values_valid = 0;
                }
                last;
            }
            $values_valid
        };
        $search_spec->{$key}->{enabled} = $valid_check;
    };
    my $result = $c->search($search_spec);

    $c->render(json => $result);
};

post '/cdr/draft' => sub ($c) {
    my $payload = $c->req->json;

    my $assessment = $payload->{assessment};
    my $patient_uuid = $payload->{header}->{uuid} or return $c->reply->not_found;

    $dbh->return_single_cell('uuid',uc $patient_uuid,'uuid') or return $c->reply->not_found;

    $assessment = Utils::fill_in_scores( $assessment );
    my $summarised = Utils::summarise_composed_assessment( Utils::compose_assessments ( $patient_uuid, $assessment ) );

    $summarised->{situation}  = $payload->{situation};
    $summarised->{background} = $payload->{background};

    $c->render( json => $summarised );
};

# get /cdr used to list templates but we don't want that now

post '/cdr' => sub ($c) {
    my $passed_composition = $c->req->json;

    my $patient_uuid = $passed_composition->{header}->{uuid} ? uc($passed_composition->{header}->{uuid}) : undef;

    if ( not defined $patient_uuid ) {
        $c->status(400);
        $c->render( json => { error => "UUID missing from header" } );
        return;
    }

    if (! $dbh->return_single_cell('uuid',$patient_uuid,'uuid')) {
        $c->status(500);
        $c->render( json => { error => "Supplied UUID ($patient_uuid) was not present in local ehr db" } );
        return;
    }

    # Create a place to put everything we need for ease and clarity

    my $xml_transformation = sub {
        my $big_href = shift->{input};
        my $tt2 = Template->new({ ENCODING => 'utf8' });

        $big_href->{header}->{start_time} = DateTime->now->strftime('%Y-%m-%dT%H:%M:%SZ');

        my $json_path = sub { JSON::Pointer->get($big_href, $_[0]) };

        $tt2->process('composition.xml.tt2', {
            json_path => $json_path,
            generate_uuid => sub { $uuid->to_string($uuid->create) } },
        \my $xml) or die $tt2->error;

        return $xml;
    };

    my $xml_composition = $xml_transformation->($passed_composition);

    # Write to /tmp for a log
    if ($ENV{DEBUG}) {
        my ($fh, $fn) = tempfile;
        binmode $fh, ':utf8';
        print $fh $xml_transformation;
        say STDERR "Composition XML is in $fn";
    }

    try {
        Utils::store_composition($patient_uuid, $xml_composition);
        $c->status(204);
    }
    catch {
        $c->status(500);
        $c->render(json => { error => $_ });
    }
};

# TODO - TAG:waresf do we need these twice?
app->plugin('SecureCORS');
app->routes->to('cors.credentials'=>1);
app->routes->to('cors.origin' => '*');
app->routes->to('cors.headers' => 'Content-Type');
app->routes->to('cors.methods' => 'GET,POST,PUT,DELETE');
app->start;

__DATA__

@@ index.html.ep
% layout 'default';
% title 'Welcome';
<h1>Welcome to the Mojolicious real-time web framework!</h1>

@@ layouts/default.html.ep
<!DOCTYPE html>
<html>
  <head><title><%= title %></title></head>
  <body>
    Click here to log in:
    <%= link_to "Connect!", $c->oauth2->auth_url("opus", scope => 'email profile openid') %>

    <%= content %>
  </body>
</html>
