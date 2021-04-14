#!/usr/bin/env perl
use Mojolicious::Lite -signatures;

use lib 'lib';
use Utils;
use EHRHelper;
use DBHelper;

use Data::UUID;
use Encode;

use Data::Dumper;

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

plugin "SecureCORS" => {
    'cors.origin' => '*',
    'cors.headers' => 'Content-Type',
    'cors.credentials' => 1,
};

my $api_prefix              =   '/c19-alpha/0.0.1';

# Load JSON / UUID mnodules
my $uuid                    =   Data::UUID->new;
my $json                    =   JSON::MaybeXS->new(utf8 => 1)->allow_nonref(1);
my $dbh                     =   DBHelper->new(1);

my $global      = {
    sessions    =>  {},
    config      =>  {
        session_timeout =>  120
    },
    handler     =>  {},
    helper      =>  {
        'days_of_week'      =>  [qw(Mon Tue Wed Thu Fri Sat Sun)],
        'months_of_year'    =>  [qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)],
    },
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
