#!/usr/bin/env perl
use Mojolicious::Lite -signatures;

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

get '/patients' => sub ($c) {
}, 'patients';

get '/patient/<:id>' => sub ($c) {
};

post '/patient/<:id>/cdr/draft' => sub ($c) {
};

post '/patient/<:id>/cdr' => sub ($c) {
};

plugin OpenAPI => { spec => curfile->dirname->sibling('openapi-schema.yml')->to_string };

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
