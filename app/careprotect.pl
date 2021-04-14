#!/usr/bin/env perl
use Mojolicious::Lite -signatures;

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

get '/c19-alpha/0.0.1/' => sub ($c) {
    $c->render(template => 'index');
};

get '/c19-alpha/0.0.1/_/auth' => sub ($c) {
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
