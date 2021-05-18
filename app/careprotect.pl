#!/usr/bin/env perl
use Mojolicious::Lite -signatures;

use lib 'lib';
use Utils;
use EHRHelper;
use DBHelper;

use Data::UUID;
use DateTime;
use File::Temp qw(tempfile);
use JSON::Pointer;
use List::Gather;
use Mojo::UserAgent;
use Mojo::File qw(curfile);
use Template;
use Try::Tiny;

use Data::Dumper;

my $api_prefix              =   '/c19-alpha/0.0.1';

# Load JSON / UUID mnodules
my $uuid                    =   Data::UUID->new;
my $json                    =   JSON::MaybeXS->new(utf8 => 1)->allow_nonref(1);

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

helper utils => sub ($c) {
    state $utils = Utils->new(
        template_path => curfile->dirname->sibling('etc'),
        dbh => $c->dbh,
    )
};

helper dbh => sub {
    state $dbh = DBHelper->new( curfile->dirname->sibling('var'), 1 );
};

helper search => sub ($c, $search_spec) {
    # FIXME: this is ripped from the POE thing and needs to use SQL to search
    # and sort
    my $search_result   =   [];

    # Sort
    if ($search_spec->{sort}->{enabled}) {
        foreach my $uuid_return ( $c->dbh->return_col_sorted('uuid',$search_spec->{sort})->@* ) {
            my $userid  =
                $uuid_return->[0];

            my $search_db_ref   =   $c->dbh->return_row(
                'uuid',
                $userid
            );

            push @{$search_result},$search_db_ref;
        }
    }
    else {
        foreach my $uuid_return ( $c->dbh->return_col('uuid')->@* ) {
            my $userid  =
                $uuid_return->[0];

            my $search_db_ref   =   $c->dbh->return_row(
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

        my $search_match = $c->dbh->search_match($search_key,$search_value);

        if ($search_match) {
            my $search_db_ref   =   $c->dbh->return_row(
                'uuid',
                $search_match
            );

            push @{$search_result},$search_db_ref;
        }
    }

    if (@$search_result) {
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

    $c->app->log->debug("Requesting token");
    $c->oauth2->get_token_p(opus => $get_token_args)->then(sub {
        $c->app->log->debug("Got a token");
        return unless my $provider_res = shift;
        $c->app->log->debug($provider_res->{access_token});
        $c->session->{token} = $provider_res->{access_token};
        $c->redirect_to("/");
    })->catch(sub {
        $c->app->log->debug("errored");
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

    for (@$result) {
        $_->{assessment} = $c->utils->summarise_composed_assessment( $c->utils->compose_assessments( $_->{uuid} ) );
    }

    $c->render(json => $result);
};

post '/cdr/draft' => sub ($c) {
    my $payload = $c->req->json;

    my $assessment = $payload->{assessment};
    my $patient_uuid = $payload->{header}->{uuid} or return $c->reply->not_found;

    $c->dbh->return_single_cell('uuid',uc $patient_uuid,'uuid') or return $c->reply->not_found;

    $assessment = $c->utils->fill_in_scores( $assessment );
    my $summarised = $c->utils->summarise_composed_assessment( $c->utils->compose_assessments ( $patient_uuid, $assessment ) );

    $summarised->{situation}  = $payload->{situation};
    $summarised->{background} = $payload->{background};

    $c->render( json => $summarised );
};

# get /cdr used to list templates but we don't want that now

post '/cdr' => sub ($c) {
    my $passed_composition = $c->req->json;

    my $patient_uuid = $passed_composition->{header}->{uuid} ? uc($passed_composition->{header}->{uuid}) : undef;

    if ( not defined $patient_uuid ) {
        $c->res->code(400);
        $c->render( json => { error => "UUID missing from header" } );
        return;
    }

    if (! $c->dbh->return_single_cell('uuid',$patient_uuid,'uuid')) {
        $c->res->code(500);
        $c->render( json => { error => "Supplied UUID ($patient_uuid) was not present in local ehr db" } );
        return;
    }

    my $xml_transformation = sub {
        my $big_href = shift->{input};
        my $tt2 = Template->new({ ENCODING => 'utf8', ABSOLUTE => 1 });

        $big_href->{header}->{start_time} = DateTime->now->strftime('%Y-%m-%dT%H:%M:%SZ');

        my $json_path = sub { JSON::Pointer->get($big_href, $_[0]) };
        my $xml_tt = curfile->dirname->sibling('etc/composition.xml.tt2')->to_abs->to_string;

        $tt2->process($xml_tt, {
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
        print $fh $xml_composition;
        say STDERR "Composition XML is in $fn";
    }

    try {
        $c->utils->store_composition($patient_uuid, $xml_composition);
        $c->res->code(204);
        $c->render(json => undef);
    }
    catch {
        $c->res->code(500);
        $c->render(json => { error => $_ });
    }
};

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

<%= link_to "Connect!", $c->oauth2->auth_url("opus", scope => 'email profile openid') %>


@@ layouts/default.html.ep
<!DOCTYPE html>
<html>
  <head><title><%= title %></title></head>
  <body>
    Click here to log in:
    <%= content %>
  </body>
</html>
