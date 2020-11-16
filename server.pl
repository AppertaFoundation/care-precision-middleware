#!perl

# Internal perl (move to 5.32.0)
use v5.30.0;

# Internal perl modules (core)
use strict;
use warnings;
use utf8;
use open qw(:std :utf8);
use experimental qw(signatures);

# Internal perl modules (debug)
use Data::Dumper;
use Carp;

use POE qw(
    Component::Server::SimpleHTTP
    Component::Client::Keepalive
    Component::Client::HTTP
    Component::Pool::DBI
);

use URI;
use URI::QueryParam;
use HTTP::Request::Common;
use HTTP::Status;
use HTTP::Cookies;

use Cookie::Baker;
use Try::Tiny;
use JSON::MaybeXS ':all';
use Data::UUID;
use DateTime;
use File::Slurp;
use Storable qw( dclone );
use Data::Search;

# Do not buffer STDOUT;
$| = 1;

# Version of this software
my $VERSION = '0.001';

my $dsn         =   'DBI:Pg:dbname=c19';
my $uuid        =   Data::UUID->new;
my $json        =   JSON::MaybeXS->new(utf8 => 1)->allow_nonref(1);

my $global      = {
    sessions    =>  {},
    config      =>  {
        session_timeout =>  120
    },
    db          =>  {},
    handler     =>  {},
    helper      =>  {
        'days_of_week'      =>  [qw(Mon Tue Wed Thu Fri Sat Sun)],
        'months_of_year'    =>  [qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)],
    },
    compose     =>  {}
};

my $pool = POE::Component::Client::Keepalive->new(
    keep_alive    => 5,    # seconds to keep connections alive
    max_open      => 100,   # max concurrent connections - total
    max_per_host  => 20,    # max concurrent connections - per host
    timeout       => 30,    # max time (seconds) to establish a new connection
);

POE::Component::Client::HTTP->spawn(
    Protocol            =>  'HTTP/1.1',
    Timeout             =>  60,
    ConnectionManager   =>  $pool,
    NoProxy             =>  [ "localhost", "127.0.0.1" ],
    Alias               =>  'webclient'
);

my $api_prefix          =   '/c19-alpha/0.0.1';
my $api_hostname        =   'api.c19.devmode.xyz';
my $api_hostname_cookie =   '.c19.devmode.xyz';

my $ehrbase             =   'http://192.168.101.2:8001';

my $www_interface   =   POE::Component::Server::SimpleHTTP->new(
    'ALIAS'         =>      'HTTPD',
    'PORT'          =>      18080,
    'HOSTNAME'      =>      $api_hostname,
    'KEEPALIVE'     =>      1,
    'HANDLERS'      =>      [
        {
            'DIR'           =>  '^/.*',
            'SESSION'       =>  'service::httpd',
            'EVENT'         =>  'process_request',
        }, 
        {
            'DIR'           =>  '.*',
            'SESSION'       =>  'service::httpd',
            'EVENT'         =>  'process_error',
        },
    ],
    'LOGHANDLER' => {
        'SESSION' => 'service::main',
        'EVENT'   => 'handle_log',
    },
    'LOG2HANDLER' => { 
        'SESSION' => 'service::main',
        'EVENT'   => 'handle_log',
    },
) or die 'Unable to create the HTTP Server';

# Create our own session to receive events from SimpleHTTP
# This is really the central session and will deal with

# events from lots of different modules
my $service_main = POE::Session->create(
    inline_states => {
        '_start'            =>  sub {
            my ($kernel,$heap) = @_[KERNEL,HEAP];
            $kernel->alias_set( 'service::main' );
            $kernel->post( 'HTTPD', 'GETHANDLERS', $_[SESSION], 'GOT_HANDLERS' );
        },
        'register_handler'  =>  sub {
            my ($kernel,$heap,$sender,$handler) = @_[KERNEL,HEAP,SENDER,ARG0];

            my $sender_id = $sender->ID;
            say "Registered: $handler (session: $sender_id)";

            $heap->{handler}->{$handler} = $sender_id;
            $global->{handler}->{$handler} = $sender_id;
        },
        'unimplemented'     =>  sub {
            my ($kernel,$heap,$sender,$id,$event,$packet) =
                @_[KERNEL,HEAP,SENDER,ARG0,ARG1,ARG2];

            my $request     =   $packet->[0]->{request};
            my $response    =   $packet->[0]->{response};

            say "[$id] Unhandled event, '$event' caught";
            $kernel->post( 'HTTPD', 'DONE', $response );
        },
    },
    heap        =>  {
        api_prefix  =>  $api_prefix
    }
);

my $service_auth = POE::Session->create(
    inline_states => {
        '_start'            =>  sub {
            my ($kernel,$heap) = @_[KERNEL,HEAP];
            $kernel->alias_set('service::auth');
        },
        'authorise'         =>  sub {
            my ($kernel,$heap,$packet)  =   @_[KERNEL,HEAP,ARG0];

            
        }
    },
);

my $service_db = POE::Session->create(
    inline_states => {
        '_start'            =>  sub {
            my ($kernel,$heap) = @_[KERNEL,HEAP];
            $kernel->alias_set('service::db');

            $heap->{dbpool} = POE::Component::Pool::DBI->new(
                connections         =>  10,
                dsn                 =>  'DBI:Pg:database=c19',
                username            =>  'c19',
                password            =>  ''
            );
            say '';

            $heap->{dbpool}->query(
                callback => "db_test",
                query    => "INSERT INTO master (id) VALUES (?)",
                params   => [ $uuid->to_string($uuid->create()) ],
                userdata => "example"
            );
        },
        'authorise'         =>  sub {
            my ($kernel,$heap,$packet)  =   @_[KERNEL,HEAP,ARG0];

            
        },
        'db_test'           =>  sub {
            my ($kernel, $heap, $results, $userdata) = 
                @_[ KERNEL, HEAP, ARG0, ARG1 ];

            say "Succesfull DB Connection test";
        },
    },
);

my $handler_root = POE::Session->create(
    inline_states => {
        '_start'            =>  sub {
            my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];

            my $handler     =   "/";
            $heap->{myid}   =   "handler::$handler";

            $kernel->alias_set($heap->{myid});
            $kernel->post(
                'service::main', 
                'register_handler',
                $heap->{myid}
            );
        },
        'process_request'   =>  sub {
            my ( $kernel, $heap, $session, $sender, $packet ) =
                @_[ KERNEL, HEAP, SESSION, SENDER, ARG0 ];

            $kernel->yield(lc($packet->{request}->method),$packet);
        },
        'post'              =>  sub {
            my ( $kernel, $heap, $session, $packet ) =
                @_[ KERNEL, HEAP, SESSION, ARG0 ];

            my $response    =   $packet->{response};
            my $request     =   $packet->{request};
            my $method      =   lc($request->method);

            $response->code( 200 );
            $response->content( 'Open eReact API - Unauthorized access is strictly forbidden.' );

            $kernel->yield('finalize', $request, $response);
        },
        'finalize'          =>  sub {
            my ( $kernel, $response ) = @_[ KERNEL, ARG0 ];
            $kernel->post( 'HTTPD', 'DONE', $response );
        },
        '_default'          =>  sub {
            my ($kernel,$heap,$event,$args) = @_[KERNEL,HEAP,ARG0,ARG1];
            $kernel->post('service::main','unimplemented',$heap->{myid},$event,$args);
        }
    }
);

my $handler_c19_alpha_0_0_1_ = POE::Session->create(
    inline_states => {
        '_start'            =>  sub {
            my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];

            my $handler     =   $api_prefix;
            $heap->{myid}   =   "handler::$handler";

            $kernel->alias_set($heap->{myid});
            $kernel->post(
                'service::main', 
                'register_handler',
                $heap->{myid}
            );
        },
        'process_request'   =>  sub {
            my ( $kernel, $heap, $session, $sender, $packet ) =
                @_[ KERNEL, HEAP, SESSION, SENDER, ARG0 ];

            $kernel->yield(lc($packet->{request}->method),$packet);
        },
        'get'              =>  sub {
            my ( $kernel, $heap, $session, $packet ) =
                @_[ KERNEL, HEAP, SESSION, ARG0 ];

            my $response    =   $packet->{response};
            my $request     =   $packet->{request};
            my $method      =   lc($request->method);

            my @handlers;
            foreach my $handler (keys %{$global->{handler}}) {
                my ($type,$path) = split(/::/,$handler);
                if ($type eq 'handler') {
                    push @handlers,$path;
                }
            }

            $response->code( 200 );
            $response->header('Content-Type' => 'application/javascript');
            $response->content( encode_json(\@handlers) );

            $kernel->yield('finalize', $response);
        },
        'finalize'          =>  sub {
            my ( $kernel, $response ) = @_[ KERNEL, ARG0 ];
            $kernel->post( 'HTTPD', 'DONE', $response );
        },
        '_default'          =>  sub {
            my ($kernel,$heap,$event,$args) = @_[KERNEL,HEAP,ARG0,ARG1];
            $kernel->post('service::main','unimplemented',$heap->{myid},$event,$args);
        }
    }
);

my $handler__cdr = POE::Session->create(
    inline_states => {
        '_start'            =>  sub {
            my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];

            my $handler     =   "$api_prefix/cdr";
            $heap->{myid}   =   "handler::$handler";

            $kernel->alias_set($heap->{myid});
            $kernel->post('service::main','register_handler',$heap->{myid});
        },
        'process_request'   =>  sub {
            my ( $kernel, $heap, $session, $sender, $packet ) =
                @_[ KERNEL, HEAP, SESSION, SENDER, ARG0 ];

            $kernel->yield(lc($packet->{request}->method),$packet);
        },
        'get'               =>  sub {
            my ( $kernel, $heap, $session, $packet ) =
                @_[ KERNEL, HEAP, SESSION, ARG0 ];

            my $request = GET($ehrbase.'/ehrbase/rest/openehr/v1/definition/template/adl1.4');
            $request->header('Accept' => 'application/json');

            $kernel->post(
                'webclient',        # posts to the 'ua' alias
                'request',          # posts to ua's 'request' state
                'response_list_templates',  # which of our states will receive the response
                $request,    # an HTTP::Request object,
                $packet
            );
        },
        'response_list_templates'   =>  sub {
            my ($kernel,$heap,$request_packet, $response_packet) = @_[KERNEL, HEAP, ARG0, ARG1];

            my $ehrbase_request         =   $request_packet->[0];
            my $packet                  =   $request_packet->[1];
            my $ehrbase_response        =   $response_packet->[0];

            my $frontend_response       =   $packet->{response};
            my $frontend_request        =   $packet->{request};

            $frontend_response->code(200);
            $frontend_response->header('Content-Type' => 'application/json');
            $frontend_response->content($ehrbase_response->decoded_content());

            $kernel->yield('finalize', $frontend_response);
        },
        'post'               =>  sub {
            my ( $kernel, $heap, $session, $packet ) =
                @_[ KERNEL, HEAP, SESSION, ARG0 ];

            my $payload = $packet->{request}->decoded_content();
            try {
                $payload = decode_json($payload);
            };

            if (
                ($payload) 
                && 
                (ref($payload) eq 'HASH')
                &&
                ($payload->{templateid})
             )  {
                my $request = GET($ehrbase.'/ehrbase/rest/openehr/v1/definition/template/adl1.4');
                $request->header('Accept' => 'application/json');

                $kernel->post(
                    'webclient',                # posts to the 'ua' alias
                    'request',                  # posts to ua's 'request' state
                    'create_new_composition',   # which of our states will receive the response
                    $request,                   # an HTTP::Request object,
                    $packet
                );
            }
            else {
                my $frontend_response = $packet->{response};
                $frontend_response->content("Invalid request");
                $frontend_response->code(400);
                $kernel->yield('finalize', $frontend_response);
            }
        },
        'create_new_composition'   =>  sub {
            my ($kernel,$heap,$request_packet, $response_packet) = @_[KERNEL, HEAP, ARG0, ARG1];

            my $packet                  =   $request_packet->[1];
            my $ehrbase_request         =   $request_packet->[0];
            my $ehrbase_response        =   $response_packet->[0];

            my $frontend_request        =   $packet->{request};
            my $frontend_response       =   $packet->{response};

            # Check the request templateid is present within the 
            my $templates_accessible    =   decode_json($ehrbase_response->decoded_content());
            my $template_requested      =   decode_json($frontend_request->decoded_content());

            if (
                (!$templates_accessible)
                ||
                (ref($templates_accessible) ne 'ARRAY')
                ||
                (!$templates_accessible->[0])
                ||
                (!$templates_accessible->[0]->{template_id})
            )
            {
                $frontend_response->content('Template not found');
                $frontend_response->code(404);
            }
            else {
                my $validated_template;
                foreach my $availible_template (@{$templates_accessible}) {
                    if (
                        ($availible_template->{template_id} eq $template_requested->{'templateid'})
                    )
                    {
                        $validated_template = $availible_template;
                        last;
                    }
                }

                if (!$validated_template) {
                    $frontend_response->content('Template not found');
                    $frontend_response->code(404);
                    $kernel->yield('finalize', $frontend_response);
                    return;
                }
 
                my $composition_id = $uuid->to_string($uuid->create());
                $global->{compose}->{$composition_id} = {
                    template_xml    =>  join('',read_file('composition.xml')),
                    template_json   =>  {},
                    template        =>  $validated_template
                };

                $frontend_response->code(201);
                $frontend_response->content(encode_json({commpositionid => $composition_id}));
                $frontend_response->header('Location' => "/cdr/compose?compositionid=$composition_id");
            }

            $kernel->yield('finalize', $frontend_response);
        },

        'finalize'          =>  sub {
            my ( $kernel, $response ) = @_[ KERNEL, ARG0 ];
            $kernel->post( 'HTTPD', 'DONE', $response );
        },
        '_default'          =>  sub {
            my ($kernel,$heap,$event,$args) = @_[KERNEL,HEAP,ARG0,ARG1];
            $kernel->post('service::main','unimplemented',$heap->{myid},$event,$args);
        }
    }
);

my $handler__cdr_compose = POE::Session->create(
    inline_states => {
        '_start'            =>  sub {
            my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];

            my $handler     =   "$api_prefix/cdr/compose";
            $heap->{myid}   =   "handler::$handler";

            $kernel->alias_set($heap->{myid});
            $kernel->post('service::main','register_handler',$heap->{myid});
        },
        'process_request'   =>  sub {
            my ( $kernel, $heap, $session, $sender, $packet ) =
                @_[ KERNEL, HEAP, SESSION, SENDER, ARG0 ];

            $kernel->yield(lc($packet->{request}->method),$packet);
        },
        'get'               =>  sub {
            my ( $kernel, $heap, $session, $packet ) =
                @_[ KERNEL, HEAP, SESSION, ARG0 ];

            my $response    =   $packet->{response};
            my $request     =   $packet->{request};
            my $method      =   lc($request->method);

            if (!$request->uri->query_param('compositionid'))
            {
                $response->code( 400 );
                $response->header('Content-Type' => 'plain/text');
                $response->content('compositionid or function missing');
                $kernel->yield('finalize', $response);
                return;
            }

            my $composition_id = $request->uri->query_param('compositionid');
            $packet->{composition_id}   =   $composition_id;

            if (!$global->{compose}->{$composition_id}) {
                $response->code( 404 );
                $response->header('Content-Type' => 'plain/text');
                $response->content('Compositionid not found');
                $kernel->yield('finalize', $response);
                return;
            }
            else {
                my $function = $request->uri->query_param('function') // 'default';
                my $handler = join('_','func',$method,$function);
                $kernel->yield($handler, $packet);
            }
        },
        'put'               =>  sub {
            my ( $kernel, $heap, $session, $packet ) =
                @_[ KERNEL, HEAP, SESSION, ARG0 ];

            my $response    =   $packet->{response};
            my $request     =   $packet->{request};
            my $method      =   lc($request->method);

            if (!$request->uri->query_param('compositionid'))
            {
                $response->code( 400 );
                $response->header('Content-Type' => 'plain/text');
                $response->content('compositionid or function missing');
                $kernel->yield('finalize', $response);
                return;
            }

            my $composition_id = $request->uri->query_param('compositionid');
            $packet->{composition_id}   =   $composition_id;

            if (!$global->{compose}->{$composition_id}) {
                $response->code( 404 );
                $response->header('Content-Type' => 'plain/text');
                $response->content('Compositionid not found');
                $kernel->yield('finalize', $response);
                return;
            }
            else {
                my $function = $request->uri->query_param('function') // 'default';
                my $handler = join('_','func',$method,$function);
                $kernel->yield($handler, $packet);
            }
        },
        'post'              =>  sub {
            my ( $kernel, $heap, $session, $packet ) =
                @_[ KERNEL, HEAP, SESSION, ARG0 ];

            my $response    =   $packet->{response};
            my $request     =   $packet->{request};
            my $method      =   lc($request->method);

            if (!$request->uri->query_param('compositionid'))
            {
                $response->code( 400 );
                $response->header('Content-Type' => 'plain/text');
                $response->content('compositionid or function missing');
                $kernel->yield('finalize', $response);
                return;
            }

            my $composition_id = $request->uri->query_param('compositionid');
            $packet->{composition_id}   =   $composition_id;

            if (!$global->{compose}->{$composition_id}) {
                $response->code( 404 );
                $response->header('Content-Type' => 'plain/text');
                $response->content('Compositionid not found');
                $kernel->yield('finalize', $response);
                return;
            }
            else {
                my $function = $request->uri->query_param('function') // 'default';
                my $handler = join('_','func',$method,$function);
                $kernel->yield($handler, $packet);
            }
        },
        'func_post_default'    =>  sub {
            my ( $kernel, $heap, $session, $packet ) =
                @_[ KERNEL, HEAP, SESSION, ARG0 ];
            
            my $response        =   $packet->{response};
            my $request         =   $packet->{request};
            my $method          =   lc($request->method);

            my $composition_id  =   $packet->{composition_id};

            # Reset to the default template of blank
            $global->{compose}->{$composition_id} = {};

            $response->code( 201 );
            $response->header('Content-Type' => 'plain/text');
            $response->content('OK');

            $kernel->yield('finalize', $response);
        },
        'func_put_default'    =>  sub {
            my ( $kernel, $heap, $session, $packet ) =
                @_[ KERNEL, HEAP, SESSION, ARG0 ];
            
            my $response        =   $packet->{response};
            my $request         =   $packet->{request};
            my $method          =   lc($request->method);

            my $composition_id  =   $packet->{composition_id};

            # Decode the JSON we was given to check its validity
            my $compilation_decoded;
            try {
                my $compilation_packet = $request->content;
                $compilation_decoded = decode_json($compilation_packet);
            } catch {
                $compilation_decoded = undef;
            };

            if (!$compilation_decoded) {
                $response->code( 400 );
                $response->header('Content-Type' => 'plain/text');
                $response->content('invalid json');
                $kernel->yield('finalize', $response);
                return;
            }

            # Reset to the default template of blank
            $global->{compose}->{$composition_id} = $compilation_decoded;

            # Dump the document
            say STDERR "Stored, composition";
            say STDERR Dumper($compilation_decoded);
            say STDERR "End of composition";

            # Tell the client it worked
            $response->code(200);
            $response->header('Content-Type' => 'plain/text');
            $response->content('OK');

            $kernel->yield('finalize', $response);
        },
        'func_get_default'    =>  sub {
            my ( $kernel, $heap, $session, $packet ) =
                @_[ KERNEL, HEAP, SESSION, ARG0 ];
            
            my $response        =   $packet->{response};
            my $composition_id  =   $packet->{composition_id};

            # Reset to the default template of blank
            my $encoded_content = 
                encode_json($global->{compose}->{$composition_id});

            # Tell the client it worked
            $response->code(200);
            $response->header('Content-Type' => 'json/application');
            $response->content($encoded_content);

            $kernel->yield('finalize', $response);
        },
        'finalize'          =>  sub {
            my ( $kernel, $response ) = @_[ KERNEL, ARG0 ];
            $kernel->post( 'HTTPD', 'DONE', $response );
        },
        '_default'          =>  sub {
            my ($kernel,$heap,$event,$args) = @_[KERNEL,HEAP,ARG0,ARG1];
            $kernel->post('service::main','unimplemented',$heap->{myid},$event,$args);
        }
    }
);

my $handler__auth = POE::Session->create(
    inline_states => {
        '_start'            =>  sub {
            my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];

            my $handler     =   "$api_prefix/_/auth";
            $heap->{myid}   =   "handler::$handler";

            $kernel->alias_set($heap->{myid});
            $kernel->post(
                'service::main', 
                'register_handler',
                $heap->{myid}
            );
        },
        'process_request'   =>  sub {
            my ( $kernel, $heap, $session, $sender, $packet ) =
                @_[ KERNEL, HEAP, SESSION, SENDER, ARG0 ];

            $kernel->yield(lc($packet->{request}->method),$packet);
        },
        'post'              =>  sub {
            my ( $kernel, $heap, $session, $packet ) =
                @_[ KERNEL, HEAP, SESSION, ARG0 ];

            my $response    =   $packet->{response};
            my $request     =   $packet->{request};
            my $method      =   lc($request->method);

            my $auth_packet_decoded;
            try {
                my $auth_packet = $request->content;
                $auth_packet_decoded = decode_json($auth_packet);
            } catch {
                $auth_packet_decoded = undef;
            };

            my $session_uuid = $packet->{uuid};

            if (
                ($auth_packet_decoded)
                &&
                ($auth_packet_decoded->{token})
                &&
                ($session_uuid)
                &&
                ($global->{sessions}->{$session_uuid})
                &&
                ($auth_packet_decoded->{token} eq 'authme')
            )
            {
                # AUTH THIS IS WHERE ROLES WOULD COME INTO IT
                $global->{sessions}->{$session_uuid}->[0]->{authed} =
                    $auth_packet_decoded->{token};

                # Should do some sort of auth call here TODO 
                $response->code( 200 );
                $response->header('Content-Type' => 'application/json');
                $response->content(
                    encode_json({ 
                        authentification    =>  'success', 
                        session             =>  $packet->{uuid},
                        id                  =>  $auth_packet_decoded->{token} 
                    }) 
                );
            }
            else {
                $response->code( 400 );
                $response->header('Content-Type' => 'text/plain');
                $response->content('Bad request');
            }

            $kernel->yield('finalize', $response);
        },
        'finalize'          =>  sub {
            my ( $kernel, $response ) = @_[ KERNEL, ARG0 ];
            $kernel->post( 'HTTPD', 'DONE', $response );
        },
        '_default'          =>  sub {
            my ($kernel,$heap,$event,$args) = @_[KERNEL,HEAP,ARG0,ARG1];
            $kernel->post('service::main','unimplemented',$heap->{myid},$event,$args);
        }
    }
);

my $handler__meta_demographics_patient = POE::Session->create(
    inline_states => {
        '_start'            =>  sub {
            my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];

            my $handler     =   "$api_prefix/meta/demographics/patient_list";
            $heap->{myid}   =   "handler::$handler";

            warn "SearchSessionX: ".$heap->{myid};

            $kernel->alias_set($heap->{myid});
            $kernel->post('service::main','register_handler',$heap->{myid});

            my $patient_list = decode_json(read_file('patients.json'));

            my @commit_list;
            foreach my $patient (@{$patient_list->{entry}}) {
                $patient->{_uuid} = $uuid->to_string($uuid->create());
                push @commit_list,$patient;
            }
            $global->{patient_db}->{entry} = \@commit_list;

            $global->{patient_db} = $patient_list;
        },
        'process_request'   =>  sub {
            my ( $kernel, $heap, $session, $sender, $packet ) =
                @_[ KERNEL, HEAP, SESSION, SENDER, ARG0 ];

            $kernel->yield(lc($packet->{request}->method),$packet);
        },
        'boop' => sub {
            warn "GOT IT";
        },
        'get'               =>  sub {
            my ( $kernel, $heap, $session, $packet ) =
                @_[ KERNEL, HEAP, SESSION, ARG0 ];

            my $response        =   $packet->{response};
            my $request         =   $packet->{request};

            $response->code(200);
            $response->header('Content-Type' => 'application/json');

            # Build a list of patients
            my $return = [];
            my $mode = $request->uri->query_param('function');

            foreach my $customer (@{$global->{patient_db}->{entry}}) {
                my $name = $customer->{resource}->{name};
                my $identifier = $customer->{_uuid};

                my $datablock = { name => $name, id => $identifier };

                if ($mode && $mode eq 'full') {
                    $datablock->{'birthDate'}   =
                        $customer->{resource}->{'birthDate'};
                    $datablock->{'gender'}      =
                        $customer->{resource}->{'gender'};
                    $datablock->{'identifier'}  =
                        $customer->{resource}->{'identifier'};
                    $datablock->{'location'}    =
                        'Bedroom';

                    $datablock->{'assessment'} = {};

                    # TODO Go make a query to ehrbase for all the latest versions
                    # of these
                    $datablock->{'assessment'}->{denwis}->{value}   =   do {
                        my $return;
                        if (int(rand(2)) == 1) {
                            $return = 1+int(rand(20));
                        }
                        $return;
                    };

                    $datablock->{'assessment'}->{covid}->{value}   =   do {
                        my $return;
                        if (int(rand(2)) == 1) {
                            $return->{suspected_symptom} = 'Some text probably';
                            $return->{exposure_to_covid} = int(rand(2));
                            $return->{test_for_covid_result} = int(rand(2));
                            $return->{recovered} = int(rand(2));
                            $return->{isolation_status} = '? What type is this';
                            $return->{test_status} = '? What type is this';
                        }
                        $return;
                    };

                    $datablock->{'assessment'}->{sepsis}->{value}   =   do {
                        my $return;
                        if (int(rand(2)) == 1) {
                            my @flags = qw(red amber grey);
                            my $selector = int(rand(1+scalar(@flags)));
                            $return->{flag} = $flags[$selector];
                        }
                        $return;
                    };

                    $datablock->{'assessment'}->{news2}->{value}   =   do {
                        my $return;
                        if (int(rand(2)) == 1) {
                            $return  = int(rand(100));
                        }
                        $return;
                    };
                }
                push @{$return},$datablock;
            }

            $response->content(encode_json($return));

            $kernel->yield('finalize', $response);
        },
        '_search'           =>  sub {
            my ( $kernel, $heap, $session, $payload ) =
                @_[ KERNEL, HEAP, SESSION, ARG0 ];

            warn "Searcxh called";

            # Response handler
            my $returned_items  = [];

            # Lets see check our arguments for the search
            my $search_system       =   $payload->{filter}->{system};
            my $search_target       =   $payload->{filter}->{target};
            my $search_match        =   $payload->{filter}->{match};

            # Loop through our patien t records looking for matching records
            foreach my $patient ( @{ $global->{patient_db}->{entry} } ) {
                # Step into the object via the path we was given to make the
                # search less heavy
                my @search_result = datasearch(
                    data    =>  $patient->{resource},
                    find    =>  [$search_target,$search_match],
                    return  =>  'container'
                );

                my $valid_match = 0;
                foreach my $search_result (@search_result) {
                    my @search_data_block =
                        datasearch(
                            data    =>  $search_result,
                            find    =>  ['system',$search_system],
                            return  =>  'container'
                        );
                    
                    if (@search_data_block > 0) {
                        push @{$returned_items},@search_data_block;
                    }
                }
            }

            return $returned_items;
        },
        'post'               =>  sub {
            my ( $kernel, $heap, $session, $packet ) =
                @_[ KERNEL, HEAP, SESSION, ARG0 ];

            my $response        =   $packet->{response};
            my $payload         =   $packet->{request}->decoded_content();

            # State handlers
            my $decode_success  =   1;
            try {
                $payload = decode_json($payload);
            } catch {
                $decode_success = 0;
            };

            if (
                !defined $payload->{filter}->{system}
                ||
                !defined $payload->{filter}->{target}
                ||
                !defined $payload->{filter}->{match}
                ||
                ref($payload->{filter}->{system}) ne ''
                ||
                ref($payload->{filter}->{target}) ne ''
                ||
                ref($payload->{filter}->{match}) ne ''
            )   { 
                $response->code(500);
                $response->header('Content-Type' => 'text/plain');
                $response->content('Invalid request format');

                $kernel->yield('finalize', $response);
                return;
            }

            my $returned_items
                = $kernel->call($session->ID,'_search',$payload);

            if (scalar(@{$returned_items})) {
                $response->code(200);
                $response->header('Content-Type' => 'application/json');
                $response->content(encode_json($returned_items));
            }
            else {
                $response->code(200);
                $response->header('Content-Type' => 'text/plain');
                $response->content('Not found');
            }

            $kernel->yield('finalize', $response);
        },
        'finalize'          =>  sub {
            my ( $kernel, $response ) = @_[ KERNEL, ARG0 ];
            $kernel->post( 'HTTPD', 'DONE', $response );
        },
        '_default'          =>  sub {
            my ($kernel,$heap,$event,$args) = @_[KERNEL,HEAP,ARG0,ARG1];
            $kernel->post('service::main','unimplemented',$heap->{myid},$event,$args);
        }
    }
);

# sub _navigate_patient_path($patient_info,$search_path) {
#     # Scan each patient for a record matching the path

#     my $patient_info_target = do {
#         my $patient_recursion_object    =   $patient_info;
#         while (defined(my $next_key = shift @{$search_path})) {
#             if (
#                 ref($patient_recursion_object) eq 'HASH'
#                 &&
#                 defined $patient_recursion_object->{$next_key}
#             ) {
#                 $patient_recursion_object = 
#                     $patient_recursion_object->{$next_key};    
#             }
#             elsif (
#                 ref($patient_recursion_object) eq 'ARRAY'
#                 &&
#                 $next_key =~ m/^\d+$/
#                 &&
#                 $next_key >= 0
#                 &&
#                 defined $patient_recursion_object->[$next_key]
#             ) {
#                 $patient_recursion_object = 
#                     $patient_recursion_object->[$next_key];
#             }
#             else {
#                 warn "Could not find it!";
#                 $patient_recursion_object = {};
#                 last;
#             }
#         }
#         $patient_recursion_object
#     };

#     return $patient_info_target;
# }

my $service_httpd   =   POE::Session->create(
    heap            =>  {
        api_prefix      =>  $api_prefix
    },
    inline_states   => {
        _start              =>  sub {
            my ($kernel,$heap) = @_[KERNEL,HEAP];

            $kernel->alias_set( 'service::httpd' );

            $kernel->post(
                'service::main',
                'register_handler',
                'service::httpd',
                {
                    init    =>  time
                }
            );
            $kernel->post( 'HTTPD', 'GETHANDLERS', $_[SESSION], 'register_handlers' );
        },
        'process_request'       =>  sub {
            # ARG0 = HTTP::Request object, ARG1 = HTTP::Response object, ARG2 = the DIR that matched
            my ( $kernel, $heap, $request, $response, $dirmatch ) = 
                @_[ KERNEL, HEAP, ARG0 .. ARG2 ];

            # Various helpful bits
            my $request_host    =   lc($request->uri->host);
            my $our_host        =   lc($api_hostname);
            my $method          =   lc($request->method);

            my $request_path    =   $request->uri->path;
            my $api_prefix      =   $heap->{api_prefix};

            # TODO respond Access-Control-Allow-Origin: * to OPTIONS HACK, also respond to raw options
            $response->header(
                'Access-Control-Allow-Origin'       => 'https://frontend.c19.devmode.xyz',
                'Access-Control-Allow-Headers'      => 'Content-Type',
                'Access-Control-Allow-Credentials'  => 'true'
            );

            # Default response
            $response->code( 501 );
            $response->content( 'Not implemented' );

            # Validation error at any point
            my $validation_error = 0;

            my $client_session  =   {
                valid                   =>  0,
                uuid                    =>  undef,
                obj                     =>  undef,
                validation_error        =>  0,
            };

            # OPTIONS hack
            if ($method eq 'options') {
                say STDERR "Requested path: '$request_path' method: OPTIONS, forcing Access-Control-Allow-Origin: * response.";
                $response->code( 204 );
                $response->header('Allow' => 'OPTIONS, GET, POST, PUT, DELETE' );
                $response->header('Access-Control-Allow-Methods' => 'OPTIONS, GET, POST, PUT, DELETE');
                $response->content('');
                $kernel->post( 'HTTPD', 'DONE', $response );
                return
            }

            # Convert any params
            my $params = do {
                my $return;
                foreach my $key ($request->uri->query_param) {
                    my @values = $request->uri->query_param($key);
                    if (
                        (scalar(@values) > 1)
                        &&
                        ($client_session->{validation_error}++ == 0)
                    )  {
                        # TODO
                        $response->content( 'Not implemented - Multivalue parameter key' );
                        last;
                    }
                    $return->{$key} = shift(@values);
                }
                $return
            };

            # Check cookie states
            if ($request->header('Cookie')) {
                my $client_cookies = crush_cookie($request->header('Cookie'));
                try {
                    my $client_session_from_cookie  = 
                        $client_cookies->{session};

                    my $client_uuid_binary  =
                        $uuid->from_string($client_session_from_cookie);

                    $client_session->{uuid}         = 
                        $uuid->to_string($client_uuid_binary);

                    my $client_uuid                 =
                            $client_session->{uuid};

                    $client_session->{obj} = 
                        $global->{sessions}->{$client_uuid};

                    $client_session->{valid} = 
                        $kernel->post($client_session->{obj},'ping');
                } catch {
                    $client_session->{valid}    = 0;
                    $client_session->{uuid}     = undef;
                    $client_session->{obj}      = undef;
                }
            }

            # Generate or capture the UUID
            my $session_uuid        =
                            $client_session->{uuid} || $uuid->to_string($uuid->create());
            my $session_uuid_fqdn   =
                            "session::$session_uuid";

            # Create a session cookie expires => 'Wed, 03-Nov-2010 20:54:16 GMT' 
            # HACK TODO
            # Remove the expiry entirely in production to make it a real session cookie
            my $expiry = do {
                my $datetime    =   DateTime->now()
                    ->add(seconds => $global->{config}->{session_timeout})
                    ->set_time_zone( 'Europe/London' );

                my $day_of_week =   
                    $global->{helper}->{days_of_week}->[$datetime->day_of_week_0];
                my $day         =   
                    $datetime->day_of_month;
                my $month       =   
                    $global->{helper}->{months_of_year}->[$datetime->month_0];
                my $year        =   
                    $datetime->year;
                my $time        =   
                    $datetime->hms;
                my $timezone    =   
                    $datetime->time_zone_short_name;

                "$day_of_week, $day-$month-$year $time $timezone"
            };

            my $cookie      =   bake_cookie(
                'session', 
                {
                    value       =>  $session_uuid,
                    path        =>  '/',
                    domain      =>  $api_hostname_cookie,
                    expires     =>  $expiry,
                    secure      =>  1,
                    samesite    =>  'lax'
                }
            );

            if      ($client_session->{validation_error}) {
                $response->code( 400 );
                $response->content( 'Invalid request' );
            }
            else    {
                local $!;

                my $valid_session_test = $kernel->post($session_uuid_fqdn,'ping');

                if ($!) {
                    # Posting to the session failed, remove it if it exists
                    delete $global->{sessions}->{$session_uuid};
                    # Then create it
                    $global->{sessions}->{$session_uuid} = new_session($session_uuid);
                }
            }

            {
                local $!;

                $response->header( 'Set-Cookie' => $cookie );

                my $post_test = $kernel->post(
                    $session_uuid_fqdn,
                    'process_request',
                    {
                        request     =>  $request,
                        response    =>  $response,
                        uuid        =>  $session_uuid,
                        dirwatch    =>  $dirmatch,
                        api_prefix  =>  $api_prefix
                    }
                );

                if ($!) {
                    $response->code( 500 );
                    $response->content( 'No valid route for request' );
                    $kernel->post( 'HTTPD', 'DONE', $response );
                }
            }
        },
        'register_handlers' =>  sub {
            # ARG0 = HANDLERS array
            my $handlers = $_[ ARG0 ];

            # Move the first handler to the last one
            push( @$handlers, shift( @$handlers ) );

            # Send it off!
            $_[KERNEL]->post( 'HTTPD', 'SETHANDLERS', $handlers );
        },
        'handle_log'        =>  sub {
            # ARG0 = HTTP::Request object, ARG1 = remote IP
            my ($request, $remote_ip) = @_[ARG0,ARG1];

            # Do some sort of logging activity.
            # If the request was malformed, $request = undef
            # CHECK FOR A REQUEST OBJECT BEFORE USING IT.
            if( $request ) {
                warn join(' ', time(), $remote_ip, $request->uri ), "\n";
            } 
            else {
                warn join(' ', time(), $remote_ip, 'Bad request' ), "\n";
            }
        }
    }
);

POE::Kernel->run();

# Client sessions
sub new_session($sessionid) {
    if ($global->{sessions}->{$sessionid}) {
        return $global->{sessions}->{$sessionid};
    }

    my $session = POE::Session->create(
        inline_states   => {
            '_start'            =>  sub {
                my ($kernel,$heap) = @_[KERNEL,HEAP];
                my $id = "session::$sessionid";

                $heap->{myid} = $id;

                $kernel->alias_set("session::$sessionid");
                $kernel->yield('_timeout');
                $kernel->yield('say',"Alias set to: $id");
            },
            '_timeout'          =>  sub {
                my ($kernel,$heap) = @_[KERNEL,HEAP];

                my $offset = time - $heap->{last_activity};

                if (
                    ($offset > $global->{config}->{session_timeout})
                    &&
                    (!$heap->{shutdown})
                ) {
                    $heap->{shutdown}   =   1;
                    my $me              =   $heap->{myid};
                    say "[$me]: Timeout";
                    $kernel->yield('shutdown',$me);
                }
                else {
                    $kernel->delay_add('_timeout' => 5);
                }
            },
            'shutdown'          =>  sub {
                my ($kernel,$heap) = @_[KERNEL,HEAP];

                my $me = $heap->{myid};

                $kernel->alias_remove($me);
                delete $global->{sessions}->{$me};
                $kernel->yield('say','Stopped');
            },
            'ping'              =>  sub {
                my ($kernel,$heap) = @_[KERNEL,HEAP];
                my $last_activity = $heap->{last_activity};
                $heap->{last_activity} = time;
                return $last_activity;
            },
            'say'               =>  sub {
                my ($kernel,$heap,$session,$text) = 
                    @_[KERNEL,HEAP,SESSION,ARG0];

                my $me      =   $heap->{myid};

                say STDERR "[$me]: $text";
            },
            'process_request'   =>  sub {
                my ($kernel,$heap,$session,$packet) = 
                    @_[KERNEL,HEAP,SESSION,ARG0];

                $heap->{last_activity}  =   time;
                $packet->{owner}        =   $heap->{myid};
                my $target              =   $packet->{request_processor};

                # Form the correct search parameters
                my $request         =   $packet->{request};
                my $response        =   $packet->{response};
                my $method          =   lc($request->method);
                my $request_path    =   $request->uri->path;

                # Mention what we are trying
                my $debug_line      =   join(
                    ' ',
                    'process_request:',
                    $request->method
                );
                $kernel->yield('say',$debug_line);
                $kernel->yield('say',$request->uri);

                {
                    local $!;

                    $kernel->post(
                        "handler::$request_path",'process_request',$packet
                    );

                    if ($!) {
                        $response->code( 501 );
                        $response->content( 'No valid route for request' );
                        $kernel->post( 'HTTPD', 'DONE', $response );
                    }
                }
            },
        },
        heap            =>  {
            last_activity   =>  time,
            myid            =>  $sessionid
        }
    );

    return $session;
}
