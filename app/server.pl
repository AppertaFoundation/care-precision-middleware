#!perl

# Internal perl (move to 5.32.0)
use v5.30.0;

# Internal perl modules (core)
use strict;
use warnings;
use utf8;
use open qw(:std :utf8);
use experimental qw(signatures);
use Encode;

# Internal perl modules (debug)
use Data::Dumper;
use Carp;

use POE qw(
    Component::Server::SimpleHTTP
    Component::Client::Keepalive
    Component::Client::HTTP
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
use Storable qw( dclone );
use DateTime;
use Path::Tiny;
use Template;
use JSON::Pointer;
use Mojo::DOM;

use File::Temp qw/tempfile/;
use Mojo::UserAgent;
use LWP::UserAgent(keep_alive => 1);
use HTTP::Request;

use OpusVL::ACME::C19;

# Wait for a connection to ehrbase so we can check if templates are already 
# availible, if not then upload it.

# Do not buffer STDOUT;
$| = 1;

# Version of this software
my $VERSION = '0.001';

POE::Component::Client::HTTP->spawn(
    Protocol            =>  'HTTP/1.1',
    Timeout             =>  60,
    ConnectionManager   =>  POE::Component::Client::Keepalive->new(
        keep_alive    => 5,     # seconds to keep connections alive
        max_open      => 100,   # max concurrent connections - total
        max_per_host  => 20,    # max concurrent connections - per host
        timeout       => 30,    # max time (seconds) to establish a new connection
    ),
    NoProxy             =>  [ "localhost", "127.0.0.1" ],
    Alias               =>  'webclient'
);

my $api_prefix              =   '/c19-alpha/0.0.1';
my $api_hostname            =   $ENV{FRONTEND_HOSTNAME} or die "set FRONTEND_HOSTNAME";
my ($api_hostname_cookie)   =   $ENV{FRONTEND_HOSTNAME} =~ m/^.*?(\..*)$/;
my $ehrbase                 =   $ENV{EHRBASE_URI} or die "set EHRBASE_URI";
my $dsn                     =   'DBI:Pg:dbname=c19';

say STDERR "ehrbase URI: $ehrbase";

# Load JSON / UUID mnodules
my $uuid                    =   Data::UUID->new;
my $json                    =   JSON::MaybeXS->new(utf8 => 1)->allow_nonref(1);

# news/db module started in LOUD mode, remove '1' to disable
my $dbh                     =   DBHelper->new(1);
my $ehrclient               =   EHRHelper->new(1,$ehrbase);
my $news2_calculator        =   OpusVL::ACME::C19->new(1);

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

# Make sure ehrbase has its base template
while (my $query = $ehrclient->con_test()) {
    if ($query->{code} == 200) {
        my $template_list = decode_json($query->{content});
        if (scalar(@{$template_list}) > 0) {
            say STDERR "Templates already detected";
            say STDERR Dumper($template_list);
            last;
        }

        my $template_raw    =   Encode::encode_utf8(path('full-template.xml')->slurp);
        my $response        =   $ehrclient->send_template($template_raw);

        if ($response->{code} == 204) {
            say STDERR "Template successfully uploaded!";
            last;
        }
        else {
            say STDERR "Critical error uploading template!";
            die;
        }
    }
    elsif ($query->{code} == 500) {
        sleep 5;
    }
}

# Make sure ehrbase is synced with our patients
foreach my $patient_ehrid_raw (@{$dbh->return_col('uuid')}) {
    my $patient_ehrid   =   $patient_ehrid_raw->[0];

    my $patient = $dbh->return_row(
        'uuid',
        $patient_ehrid
    );

    foreach my $validation_check_key (qw(name birth_date birth_date_string name_search gender location nhsnumber)) {
        if (!defined($patient->{$validation_check_key})) {
            say STDERR "WARNING: $patient_ehrid has NULL $validation_check_key";
        }
    }

    my $patient_name        =   $patient->{'name'};
    my $patient_nhsnumber   =   $patient->{'nhsnumber'};
    my $res                 =   $ehrclient->check_ehr_exists($patient_nhsnumber);

    if ($res->{code} != 200) {
        my $create_record = $ehrclient->create_ehr(
            $patient_ehrid,
            $patient_name,
            $patient_nhsnumber
        );

        if ($create_record->{code} != 204)  {
            die "Failure creating patient!";
        }
    }

    say "Patient " 
        . $patient_ehrid
        . ' linked with: '
        . $patient_nhsnumber
        . ' '
        . $patient_name;
}

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
        'get'               =>  sub {
            my ( $kernel, $heap, $session, $packet ) =
                @_[ KERNEL, HEAP, SESSION, ARG0 ];

            my $response    =   $packet->{response};
            my $request     =   $packet->{request};
            my $method      =   lc($request->method);

            $response->code( 200 );
            $response->header('Content-Type' => 'text/text');
            $response->content('Open eReact API - Unauthorized access is strictly forbidden.');

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

my $handler__cdr_draft = POE::Session->create(
    inline_states => {
        '_start'            =>  sub {
            my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];

            my $handler     =   "$api_prefix/cdr/draft";
            $heap->{myid}   =   "handler::$handler";

            $kernel->alias_set($heap->{myid});
            $kernel->post('service::main','register_handler',$heap->{myid});
        },
        'process_request'   =>  sub {
            my ( $kernel, $heap, $session, $sender, $packet ) =
                @_[ KERNEL, HEAP, SESSION, SENDER, ARG0 ];

            $kernel->yield(lc($packet->{request}->method),$packet);
        },
        'post'               =>  sub {
            my ( $kernel, $heap, $session, $packet ) =
                @_[ KERNEL, HEAP, SESSION, ARG0 ];

            my $payload = decode_json($packet->{request}->decoded_content());

            my $assessment      =
                $payload->{assessment};
            my $patient_uuid    =
                $payload->{header}->{uuid} ? uc($payload->{header}->{uuid}) : undef;

            say STDERR "-"x10 . " Assessment(/cdr/draft) Dump begin " . "-"x10;
            say STDERR Dumper($assessment);
            say STDERR "-"x10 . " Assessment(/cdr/draft) Dump _end_ " . "-"x10;

            if (defined $patient_uuid && $dbh->return_single_cell('uuid',$patient_uuid,'uuid')) {
                my $patient = my $search_db_ref   =   $dbh->return_row(
                    'uuid',
                    $patient_uuid
                );

                $patient->{situation}  = $payload->{situation};
                $patient->{background} = $payload->{background};

                $assessment = fill_in_scores( $assessment );
                my $summarised = summarise_composed_assessment( compose_assessments ( $patient_uuid, $assessment ) );

                $summarised->{situation}  = $patient->{situation};
                $summarised->{background} = $patient->{background};

                $packet->{response}->code(200);
                $packet->{response}->header('Content-Type' => 'application/json');
                $packet->{response}->content(encode_json($summarised));
            }
            else {
                print STDERR "Refusing to process draft call, error with uuid validation.";
            }

            $kernel->yield('finalize', $packet->{response});
        },
        'finalize'          =>  sub {
            my ( $kernel, $response ) = @_[ KERNEL, ARG0 ];
            $kernel->post( 'HTTPD', 'DONE', $response );
        },
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
                'webclient',                # posts to the 'ua' alias
                'request',                  # posts to ua's 'request' state
                'response_list_templates',  # which of our states will receive the response
                $request,                   # an HTTP::Request object,
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
             )  {
                $kernel->yield(
                    'create_new_composition',       # which of our states will receive the response
                    $payload,$packet->{response}  # a tag or object to pass things like a stash
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
            my ($kernel,$heap,$passed_objects, $frontend_response) = @_[KERNEL, HEAP, ARG0, ARG1];

            my $valid_template_test =   do  { 1 };

            # If an invalid template or JSON then return that now
            if (
                $valid_template_test == 0
                || ref($passed_objects) ne 'HASH'
            ) {
                $frontend_response->content("Invalid request");
                $frontend_response->code(400);
                $kernel->yield('finalize', $frontend_response);
                return;
            }

            # We have a valid templateid request lets proceed with creating a composition!
            my $patient_uuid = $passed_objects->{header}->{uuid} ? uc($passed_objects->{header}->{uuid}) : undef;

            # If the patient uuid is invalid, return error
            say STDERR "-"x10 . " Assessment(/cdr) Dump begin " . "-"x10;
            say STDERR Dumper($passed_objects);
            say STDERR "-"x10 . " Assessment(/cdr) Dump _end_ " . "-"x10;

            if (!defined $patient_uuid || !$dbh->return_single_cell('uuid',$patient_uuid,'uuid')) {
                my $error_str = "Supplied UUID was missing from header or not a valid ehrid UUID.";
                if (!defined $patient_uuid) { $error_str = "A UUID was not found to be defined in the header"; }
                else { $error_str = "Supplied UUID($patient_uuid) was not present in local ehr db"; }
                say STDERR "Returning: $error_str";
                $frontend_response->header('Content-Type' => 'text/text');
                $frontend_response->content("Supplied UUID was missing from header or not a valid ehrid UUID.");
                $frontend_response->code(500);
                $kernel->yield('finalize', $frontend_response);
                return;
            }

            # Create a place to put everything we need for ease and clarity
            my $composition_uuid = $uuid->to_string($uuid->create());
            my $composition_obj =   {
                'uuid'  =>  $composition_uuid,
                'input' =>  $passed_objects
            };

            my $xml_transformation = sub {
                my $big_href    =   shift->{input};
                my $tt2         =   Template->new({ ENCODING => 'utf8' });

                $big_href->{header}->{start_time} = DateTime->now->strftime('%Y-%m-%dT%H:%M:%SZ');

                my $json_path = sub { JSON::Pointer->get($big_href, $_[0]) };

                $tt2->process('composition.xml.tt2', {
                    json_path => $json_path,
                    generate_uuid => sub { $uuid->to_string($uuid->create) } },
                \my $xml) or die $tt2->error;

                return $xml;
            };

            $composition_obj->{output}  =   $xml_transformation->($composition_obj);

            # Write to /tmp for a log
            my $comp_path = '/tmp/'.time.".log";
            say STDERR "Composition raw dump: $comp_path";
            path($comp_path)->spew($composition_obj->{output});

            my $ua = Mojo::UserAgent->new;

            my $req_url = "$ehrbase/ehrbase/rest/openehr/v1/ehr/$patient_uuid/composition";

            my $tx          =   $ua->post(
                $req_url, {
                    'Content-Type'  =>  'application/xml',
                    Accept          =>  '*/*'
                } => encode_utf8($composition_obj->{output})
            );
            my $response    =   $tx->res;

            if ($response->code != 204) {
                my $error_str = "The fullowing message was returned by ehrbase:\n".$response->to_string;
                say STDERR "Returning: $error_str";
                $frontend_response->header('Content-Type' => 'text/text');
                $frontend_response->content($error_str);
                $frontend_response->code(500);
                $kernel->yield('finalize', $frontend_response);
                return;
            }

            # Finally return the XML file so we can see the results
            #$frontend_response->header('Content-Type' => 'application/xml');
            #$frontend_response->content(encode_utf8($composition_obj->{output}));
            $frontend_response->code(204);
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

            my $response        =   $packet->{response};
            my $request         =   $packet->{request};
            my $params          =   $packet->{params};

            $response->code(200);
            $response->header('Content-Type' => 'application/json');

            # Build a list of queries
            my $return_spec     =   {
                search      =>  {
                    key     =>  $params->{'search_key'},
                    value   =>  $params->{'search_value'}
                },
                sort        =>  {
                    key     =>  $params->{'sort_key'},
                    value   =>  $params->{'sort_value'}
                },
            };

            # Add in fast checks
            foreach my $key (keys %{$return_spec}) {
                my $valid_check = do {
                    my $values_valid = 1;
                    foreach my $subkey (keys %{$return_spec->{$key}}) {
                        if (!defined $return_spec->{$key}->{$subkey}) {
                            $values_valid = 0;
                        }
                        last;
                    }
                    $values_valid
                };
                $return_spec->{$key}->{enabled} = $valid_check;
            }

            # Call the search function and apply our filter sets
            # This should really be a post and the search handler should
            # simply take a reference to what to search upon (load offsetting)
            my $result = $kernel->call(
                $session->ID,
                'search',
                $return_spec 
            );

            for (@$result) {
                $_->{assessment} = summarise_composed_assessment( compose_assessments( $_->{uuid} ) )
            }

            $response->content(encode_json($result));

            $kernel->yield('finalize', $response);
        },
        'search'            =>  sub {
            my ( $kernel, $heap, $session, $search_spec ) =
                @_[ KERNEL, HEAP, SESSION, ARG0 ];

            my $search_result   =   [];

            # Filter

            # Sort
            if ($search_spec->{sort}->{enabled}) {
                foreach my $uuid_return ( @{ $dbh->return_col_sorted('uuid',$search_spec->{sort}) }) {
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
            if ($search_spec->{search}->{enabled} == 1) {
                # Frontend sends id, when it should send uuid
                my $search_key      =   'uuid';
                if ($search_spec->{search}->{key} ne 'id')    {
                    $search_key = $search_spec->{search}->{key};
                }
                my $search_value    =
                    $search_spec->{search}->{value};

                my $search_match = $dbh->search_match($search_key,$search_value);

                if ($search_match) {
                    my $search_db_ref   =   $dbh->return_row(
                        'uuid',
                        $search_match
                    );

                    push @{$search_result},$search_db_ref;
                }
            }

            if (scalar @{$search_result} > 0) {
                say STDERR "Compatability function in use for birth_date, at line: ".__LINE__;
                map { 
                    $_->{birthDate} = $_->{birth_date}; 
                    $_->{birthDateAsString} = $_->{birth_date_string};
                    $_->{id} = $_->{uuid}
                } @{$search_result};
            }

            # If no pagination just return whatever survived the run
            return $search_result;
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
                'Access-Control-Allow-Origin'       => '*',
                'Access-Control-Allow-Headers'      => 'Content-Type',
                'Access-Control-Allow-Credentials'  => 'true'
            );

            # Default response
            $response->code( 501 );

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
                        params      =>  $params,
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

sub get_compositions($patient_uuid) {
    if (!defined $patient_uuid) {
        die "No uuid passed to function";
    }

    my $valid_uuid = $dbh->return_single_cell('uuid',$patient_uuid,'uuid');

    if (!$valid_uuid) {
        # FUCK
        $patient_uuid = $valid_uuid;
        say STDERR "Invalid UUID passed to get_compositions UUID:($patient_uuid)";
        die;
    }

    $patient_uuid = $valid_uuid;

    my $composition_objs = do {
        my $query = {
            'q'    =>  "SELECT c/uid/value FROM EHR e [ehr_id/value = '$patient_uuid'] CONTAINS COMPOSITION c"
        };

        my $request = POST(
            "$ehrbase/ehrbase/rest/openehr/v1/query/aql",
            'Accept'        =>  'application/json',
            'Content-Type'  =>  'application/json',
            Content         =>  encode_json($query)
        );

        my $ua = LWP::UserAgent->new();
        my $res = $ua->request($request);

        if ($res->code != 200)  {
            print STDERR "Invalid AQL query";
            die;
        }

        my $raw_obj = decode_json($res->content());
        $raw_obj->{rows}
    };

    my $retrieve_composition = sub {
        my ($ehrid,$compositionid) = @_;

        if (!$ehrid || !$compositionid) { 
            say STDERR "ehrid or compositionid was missing, line: __LINE__";
            die;
        }

        my $query = {
            'q'    =>  "SELECT c/uid/value FROM EHR e [ehr_id/value = '$patient_uuid'] CONTAINS COMPOSITION c"
        };

        my $request = GET(
            "$ehrbase/ehrbase/rest/openehr/v1/ehr/$ehrid/composition/$compositionid",
            'Accept'       => 'application/xml',
            'Content-Type' => 'application/json',
            Content        =>   encode_json($query)
        );

        my $ua = LWP::UserAgent->new();
        my $res = $ua->request($request);

        if ($res->code != 200)  {
            print STDERR "Invalid AQL query";
            die;
        }
        $res->decoded_content();
    };

    my $get_node_with_name = sub ($dom, $name) {
        my $node = $dom->find('name > value')->grep(sub { $_->text eq $name })->first;

        if ($node) {
            return $node->parent->parent;
        }

        return;
    };

    my $dig_into_xml_for = sub ($dom, @path) {
        for my $spec (@path) {
            if (ref $spec eq 'HASH' and $spec->{name}) {
                $dom = $dom->$get_node_with_name($spec->{name});
            }
            elsif (!$dom) {
                return "";
            }
            else {
                my $node = $dom->at($spec);

                if (! $node) {
                    say STDERR "Nothing found for $spec in: \n\n $dom";
                    return;
                }

                $dom = $node->text;
            }
        }

        return $dom;
    };

    my @assessments;
    foreach my $composition (@{$composition_objs}) {
        my $xml_string = $retrieve_composition->($patient_uuid,$composition->[0]);
        my ($fh, $fn) = tempfile;
        binmode $fh, ':utf8';
        say STDERR $fn;
        my $xml = Mojo::DOM->with_roles('+PrettyPrinter')->new($xml_string);
        print $fh $xml->to_pretty_string;

        my $news2_node = $get_node_with_name->($xml, 'NEWS2');

        if ($news2_node) {
            my $news2_score = $news2_node->$get_node_with_name('NEWS2 Score');
            $news2_score->remove;

            push @assessments, {
                'news2' => {
                    'respirations' => {
                        'magnitude' => $news2_node->$dig_into_xml_for({ name => 'Respirations'}, 'magnitude'),
                    },
                    'spo2' => $news2_node->$dig_into_xml_for({ name => 'SpO₂'}, 'numerator'),
                    'systolic' => {
                        'magnitude' => $news2_node->$dig_into_xml_for({ name => 'Systolic' }, 'magnitude'),
                    },
                    'diastolic' => {
                        'magnitude' => $news2_node->$dig_into_xml_for({ name => 'Diastolic' }, 'magnitude'),
                    },
                    'pulse' => {
                        'magnitude' => $news2_node->$dig_into_xml_for({ name => 'Pulse Rate' }, 'magnitude'),
                    },
                    'acvpu' => {
                        'code' => $news2_node->$dig_into_xml_for({ name => 'ACVPU' }, 'value code_string'),
                        'value' => $news2_node->$dig_into_xml_for({ name => 'ACVPU' }, 'value > value'),
                    },
                    'temperature' => {
                        'magnitude' => $news2_node->$dig_into_xml_for({ name => 'Temperature' }, { name => 'Temperature' }, 'magnitude'),
                    },
                    'inspired_oxygen' => {
                        'method_of_oxygen_delivery' => $news2_node->$dig_into_xml_for({ name => "Method of oxygen delivery" }, 'value value'),
                        'flow_rate' => {
                            'magnitude' => $news2_node->$dig_into_xml_for({ name => "Flow rate" }, 'magnitude')
                        }
                    },
                    'score' => {
                        'systolic_blood_pressure' => {
                            'code' => $news2_score->$dig_into_xml_for({ name => "Systolic blood pressure" }, 'code_string'),
                            'value' => $news2_score->$dig_into_xml_for({ name => "Systolic blood pressure" }, 'value > symbol > value'),
                            'ordinal' => $news2_score->$dig_into_xml_for({ name => "Systolic blood pressure" }, 'value[xsi\:type] > value'),
                        },
                        'pulse' => {
                            'code' => $news2_score->$dig_into_xml_for({ name => "Pulse" }, 'code_string'),
                            'value' => $news2_score->$dig_into_xml_for({ name => "Pulse" }, 'value > symbol > value'),
                            'ordinal' => $news2_score->$dig_into_xml_for({ name => "Pulse" }, 'value[xsi\:type] > value'),
                        },
                        'respiration_rate' => {
                            'code' => $news2_score->$dig_into_xml_for({ name => "Respiration rate" }, 'code_string'),
                            'value' => $news2_score->$dig_into_xml_for({ name => "Respiration rate" }, 'value > symbol > value'),
                            'ordinal' => $news2_score->$dig_into_xml_for({ name => "Respiration rate" }, 'value[xsi\:type] > value'),
                        },
                        'temperature' => {
                            'code' => $news2_score->$dig_into_xml_for({ name => "Temperature" }, 'code_string'),
                            'value' => $news2_score->$dig_into_xml_for({ name => "Temperature" }, 'value > symbol > value'),
                            'ordinal' => $news2_score->$dig_into_xml_for({ name => "Temperature" }, 'value[xsi\:type] > value'),
                        },
                        'consciousness' => {
                            'code' => $news2_score->$dig_into_xml_for({ name => "Consciousness" }, 'code_string'),
                            'value' => $news2_score->$dig_into_xml_for({ name => "Consciousness" }, 'value > symbol > value'),
                            'ordinal' => $news2_score->$dig_into_xml_for({ name => "Consciousness" }, 'value[xsi\:type] > value'),
                        },
                        'spo_scale_1' => {
                            'code' => $news2_score->$dig_into_xml_for({ name => "SpO₂ Scale 1" }, 'code_string'),
                            'value' => $news2_score->$dig_into_xml_for({ name => "SpO₂ Scale 1" }, 'value > symbol > value'),
                            'ordinal' => $news2_score->$dig_into_xml_for({ name => "SpO₂ Scale 1" }, 'value[xsi\:type] > value'),
                        },
                        'air_or_oxygen' => {
                            'value' => $news2_score->$dig_into_xml_for({ name => "Air or oxygen?" }, 'value > symbol > value'),
                            'code' => $news2_score->$dig_into_xml_for({ name => "Air or oxygen?" }, 'code_string'),
                            'ordinal' => $news2_score->$dig_into_xml_for({ name => "Air or oxygen?" }, 'value[xsi\:type] > value'),
                        },
                        'clinical_risk_category' => {
                            'value' => $news2_score->$dig_into_xml_for({ name => "Clinical risk category" }, 'value[xsi\:type] > value'),
                            'code' => $news2_score->$dig_into_xml_for({ name => "Clinical risk category" }, 'code_string'),
                        },
                        'total_score' => $news2_score->$dig_into_xml_for({ name => "Total score" }, 'value[xsi\:type] > magnitude'),
                    },
                }
            };
        }
    }

    return @assessments;
}

sub compose_assessments($patient_uuid, @extra) {
    # Put a draft assesment in @extra. You can do multiple I suppose.

    my $composed = {};

    for my $composition (@extra, get_compositions($patient_uuid)) {
        if ($composition->{denwis}) {
            if (not $composed->{denwis}) {
                # Shallow copy for when we add trend to it later
                $composed->{denwis} = { $composition->{denwis}->%* };
            }
            elsif (not $composed->{denwis}->{trend}) {
                # The new score ($composed) goes on the left of the <=>
                $composed->{denwis}->{trend} =
                ( qw(same increasing decreasing) )[
                    $composed->{denwis}->{total_score} <=> $composition->{denwis}->{total_score}
                ]
            }
        }

        if ($composition->{sepsis}) {
            if (not $composed->{sepsis}) {
                # Shallow copy for when we add trend to it later
                $composed->{sepsis} = { $composition->{sepsis}->%* };
            }
        }

        if ($composition->{news2}) {
            if (not $composed->{news2}) {
                # Shallow copy for when we add trend to it later
                $composed->{news2} = { $composition->{news2}->%* };
            }
            elsif (not $composed->{news2}->{trend}) {
                # The new score ($composed) goes on the left of the <=>
                $composed->{news2}->{trend} =
                ( qw(same increasing decreasing) )[
                    $composed->{news2}->{score}->{total_score} <=> $composition->{news2}->{score}->{total_score}
                ]
            }
        }
    }

    # Why write stuff like this >.> it could be made so much clearer just 
    # taking up a tiny bit more vertical height.... (comment by pgw)
    $composed->{$_}->{trend} //= 'first' for grep exists $composed->{$_}, qw/denwis news2/;

    return $composed;
}

sub summarise_composed_assessment {
    my $composed = shift;
    my $summary = {};

    if ($composed->{denwis}) {
        $summary->{denwis}->{value} = {
            value       =>  $composed->{denwis}->{total_score},
            trend       =>  $composed->{denwis}->{trend},
        }
    }

    if ($composed->{sepsis}) {
        $summary->{sepsis}->{value} = {
            value       =>  $composed->{sepsis}->{value},
            score       =>  $composed->{news2}->{score}
        }
    }

    if ($composed->{news2}) {
        $summary->{news2}   =   do {
            {
                clinicalRisk    =>  $news2_calculator->calculate_clinical_risk($composed->{news2}),
                score           =>  $composed->{news2}->{score},
                trend           =>  $composed->{news2}->{trend},
            };
        };
    }

    if ($composed->{covid}) {
        $summary->{covid}->{value}   =   do {
            my $return;
            my @flags = qw(red amber grey green);

            $return->{suspected_covid_status} =
                    $flags[rand @flags];
            $return->{date_isolation_due_to_end} =
                '2020-11-10T22:39:31.826Z';
            $return->{covid_test_request} =  {
                'date'  =>  '2020-11-10T22:39:31.826Z',
                'value' =>  'EXAMPLE TEXT'
            };

            $return;
        };
    }

    return $summary;
}

sub fill_in_scores {
    # just adds total_scores or whatever to the assessment
    my $assessment = shift;

    if ($assessment->{denwis}) {
        $assessment->{denwis}->{total_score} = (int rand 20) + 1;
    }

    if ($assessment->{sepsis}) {
        $assessment->{sepsis}->{value} = (qw/red green amber grey/)[rand 4];
    }

    if ($assessment->{news2}) {
        my $news2_scoring = $news2_calculator->news2_calculate_score({
            'respiration_rate'          =>  $assessment->{news2}->{respiration_rate}->{magnitude},
            'spo2_scale_1'              =>  $assessment->{news2}->{spo2},
            'pulse'                     =>  $assessment->{news2}->{pulse}->{magnitude},
            'temperature'               =>  $assessment->{news2}->{temperature}->{magnitude},
            'systolic_blood_pressure'   =>  $assessment->{news2}->{systolic}->{magnitude},
            'air_or_oxygen'             =>  defined($assessment->{news2}->{inspired_oxygen}->{flow_rate}) ? 'Oxygen' : 'Air',
            'consciousness'             =>  do {
                my $return_value;
                my $submitted_value =   defined($assessment->{news2}->{acvpu}->{value}) ? $assessment->{news2}->{acvpu}->{value} : undef;
                if      ($submitted_value =~ m/^Confused|Confusion|Voice|Pain|Unresponsive|CVPU$/i)   { $return_value = 'CVPU' }
                elsif   ($submitted_value =~ m/^Alert$/i)                                   { $return_value = 'Alert' }
                $return_value
            }
        });

        # I need to fill in this with the real results:
        $assessment->{news2}->{score} = {
            "respiration_rate" => {
              "code"    => $news2_scoring->{news2}->{respiration_rate}->[2],
              "value"   => $news2_scoring->{news2}->{respiration_rate}->[1],
              "ordinal" => $news2_scoring->{news2}->{respiration_rate}->[0]
            },
            "spo_scale_1" => {
              "code"    => $news2_scoring->{news2}->{spo2_scale_1}->[2],
              "value"   => $news2_scoring->{news2}->{spo2_scale_1}->[1],
              "ordinal" => $news2_scoring->{news2}->{spo2_scale_1}->[0]
            },
            "air_or_oxygen" => {
              "code"    => $news2_scoring->{news2}->{air_or_oxygen}->[2],
              "value"   => $news2_scoring->{news2}->{air_or_oxygen}->[1],
              "ordinal" => $news2_scoring->{news2}->{air_or_oxygen}->[0]
            },
            "systolic_blood_pressure" => {
              "code"    => $news2_scoring->{news2}->{systolic_blood_pressure}->[2],
              "value"   => $news2_scoring->{news2}->{systolic_blood_pressure}->[1],
              "ordinal" => $news2_scoring->{news2}->{systolic_blood_pressure}->[0]
            },
            "pulse" => {
              "code"    => $news2_scoring->{news2}->{pulse}->[2],
              "value"   => $news2_scoring->{news2}->{pulse}->[1],
              "ordinal" => $news2_scoring->{news2}->{pulse}->[0]
            },
            "consciousness" => {
              "code"    => $news2_scoring->{news2}->{consciousness}->[2],
              "value"   => $news2_scoring->{news2}->{consciousness}->[1],
              "ordinal" => $news2_scoring->{news2}->{consciousness}->[0]
            },
            "temperature" => {
              "code"    => $news2_scoring->{news2}->{temperature}->[2],
              "value"   => $news2_scoring->{news2}->{temperature}->[1],
              "ordinal" => $news2_scoring->{news2}->{temperature}->[0]
            },
            "total_score" => $news2_scoring->{state}->{score}
        };

        # Add in clinical risk
        $assessment->{news2}->{clinicalRisk} =
            $news2_calculator->calculate_clinical_risk($assessment->{news2}->{score});
    }

    if ($assessment->{covid}) {
        # no idea
    }

    # It edits it in-place because I'm lazy - returning it is good practice
    return $assessment;
}





package DBHelper;

# Internal perl modules (core)
use strict;
use warnings;

# Internal perl modules (core,recommended)
use utf8;
use experimental qw(signatures);

# Debug/Reporting modules
use Carp qw(cluck longmess shortmess);
use Data::Dumper;

# We need SQLite as well
use DBI;

# Primary code block
sub new($class,$set_debug = 0) {
    my $dbh = DBI->connect(
        'dbi:SQLite:dbname=patient.db',
        '',
        '',
        {
            'AutoCommit'                    =>  1,
            'RaiseError'                    =>  1, 
            'sqlite_see_if_its_a_number'    =>  1
        }
    );

    my $self = bless {
        'dbh'   =>  $dbh,
        'debug' =>  $set_debug
    }, $class;

    # Double check the table exists and has content
    my $create_table    =   $self->check_table_exist('patient');

    if ($self->{debug}) {
        say STDERR "Create table: $create_table"
    }

    if ($create_table == 0) {
        $self->init_data($create_table);
    }
    my $row_count = $self->row_count();

    if ($self->{debug}) { 
        say STDERR "Row count is now: $row_count";
    }

    return $self;
}

sub init_data($self,$create_table) {
    if ($create_table == 0) {
        $self->{dbh}->do("CREATE TABLE patient (uuid string PRIMARY KEY,name string NOT NULL,birth_date number NOT NULL,birth_date_string string NOT NULL,name_search string NOT NULL,gender string NOT NULL, location string default 'Bedroom', nhsnumber number NOT NULL)");
    }
    $self->{dbh}->do("INSERT INTO patient(uuid,name,birth_date,birth_date_string,name_search,gender,location,nhsnumber) VALUES('C7008950-79A8-4CE8-AC4E-975F1ACC7957','Miss Praveen Dora','19980313','1998-03-13','Praveen Dora','female','Bedroom','9876543210')");
    $self->{dbh}->do("INSERT INTO patient(uuid,name,birth_date,birth_date_string,name_search,gender,location,nhsnumber) VALUES('89F0373B-CA53-41DF-8B54-0142EF3DDCD7','Mr HoratioSamson','19701016','1970-10-16','Horatio Samson','male','Bedroom','9876543211')");
    $self->{dbh}->do("INSERT INTO patient(uuid,name,birth_date,birth_date_string,name_search,gender,location,nhsnumber) VALUES('0F878EC8-FECE-42DE-AE4E-F76BEFB902C2','Mrs Elsie Mills-Samson','19781201','1978-12-01','Elsie Mills-Samson','male','Bedroom','9876512345')");
    $self->{dbh}->do("INSERT INTO patient(uuid,name,birth_date,birth_date_string,name_search,gender,location,nhsnumber) VALUES('220F7990-666E-4D64-9CBB-656051CE1E84','Mrs Fredrica Smith','19651213','1965-12-13','Fredrica Smith','female','Bedroom','3333333333')");
    $self->{dbh}->do("INSERT INTO patient(uuid,name,birth_date,birth_date_string,name_search,gender,location,nhsnumber) VALUES('5F7C7670-419B-40E6-9596-AC39D670BF15','Miss Kendra Fitzgerald','19420528','1942-05-28','Kendra Fitzgerald','female','Bedroom','9564963656')");
    $self->{dbh}->do("INSERT INTO patient(uuid,name,birth_date,birth_date_string,name_search,gender,location,nhsnumber) VALUES('4152DEC6-45E0-4EEE-A9DD-B233F1A07561','Mrs Christine Taylor','19230814','1923-08-14','Christine Taylor','female','Bedroom','9933157213')");
    $self->{dbh}->do("INSERT INTO patient(uuid,name,birth_date,birth_date_string,name_search,gender,location,nhsnumber) VALUES('F6F1741D-BECA-4357-A23F-DD2B2FF934B9','Miss Darlene Cunningham','19980609','1998-06-09','Darlene Cunningham','female','Bedroom','9712738531')");
}

sub check_table_exist($self,$tablename) {
    my $sth = $self->{dbh}->prepare("SELECT count('name') FROM sqlite_master WHERE type='table' AND name=?");
    $sth->execute($tablename);
    my $row = $sth->fetch;
    return $row->[0] ? 1 : 0;
}

sub row_count($self) {
    my $sth = $self->{dbh}->prepare("SELECT count('uuid') FROM patient");
    $sth->execute();
    my $row = $sth->fetch;
    return ($row->[0] + 0);
}

sub return_col($self,$col_name) {
    my $sql_str =   "SELECT $col_name FROM patient";
    my $sth     =   $self->{dbh}->prepare($sql_str);
    $sth->execute();
    return $sth->fetchall_arrayref;
}

sub return_col_sorted($self,$col_name,$sort_spec = {}) {
    my $sql_str =   "SELECT $col_name FROM patient";

    if (
        $self->check_valid_col($sort_spec->{key})
        &&
        $sort_spec->{value} =~ m/^ASC|DESC$/
    ) {
        $sql_str .= join(' ',' ORDER BY',$sort_spec->{key},$sort_spec->{value});
    }

    my $sth     =   $self->{dbh}->prepare($sql_str);
    $sth->execute();
    return $sth->fetchall_arrayref;
}

sub check_valid_col($self,$col_name) {
    my $sql_str =   "SELECT COUNT(*) AS CNTREC FROM pragma_table_info('PATIENT') WHERE name=?";
    my $sth     =   $self->{dbh}->prepare($sql_str);
    $sth->execute($col_name);
    my $row = $sth->fetch;
    return ($row->[0] + 0);
}

sub return_single_cell($self,$col_name,$col_value,$target_col_name) {
    my $sql_str =   "SELECT $target_col_name FROM patient WHERE $col_name = ?";
    my $sth     =   $self->{dbh}->prepare($sql_str);
    $sth->execute($col_value);
    my $sql_return = $sth->fetch;
    return $sql_return->[0] ? $sql_return->[0] : undef;
}

sub return_row($self,$col_name,$col_value) {
    my $sql_str =   "SELECT * FROM patient WHERE $col_name = ? LIMIT 1";
    my $sth     =   $self->{dbh}->prepare($sql_str);
    $sth->execute($col_value);
    my $intermediatory_return = $sth->fetchall_hashref($col_name);
    if (!defined($intermediatory_return->{$col_value})) { 
        return {};
    } else {
        return $intermediatory_return->{$col_value};
    }
}

sub search_match($self,$search_key,$search_value) {
    my $sql_str =   "SELECT uuid FROM patient WHERE $search_key = ? LIMIT 1";

    if (
        $search_key !~ m/^[a-z]+$/i
        ||
        !$self->check_valid_col($search_key)
    ) {
        return undef;
    }

    my $sth     =   $self->{dbh}->prepare($sql_str);
    $sth->execute($search_value);
    my $row = $sth->fetch;

    if (scalar(@{$row}) == 1) { 
        return $row->[0];
    }
    else {
        say STDERR "WARNING: Returning undef to search_match";
        return undef;
    }
}

package EHRHelper;

# Internal perl modules (core)
use strict;
use warnings;

# Internal perl modules (core,recommended)
use utf8;
use experimental qw(signatures);

# Debug/Reporting modules
use Carp qw(cluck longmess shortmess);
use Data::Dumper;

# Add in the HTTP modules, not mojo :)
use URI;
use URI::QueryParam;
use HTTP::Request;
use HTTP::Request::Common;
use HTTP::Status;
use HTTP::Cookies;
use LWP::UserAgent;

# Some JSON hackery
use JSON::MaybeXS ':all';

# Primary code block
sub new($class,$set_debug = 0,$ehrbase = 'http://localhost:8080') {
    my $debug = 0;
    if ($set_debug) { $debug = 1 }

    my $self = bless {
        agent   =>  LWP::UserAgent->new(),
        ehrbase =>  $ehrbase,
        debug   =>  $debug
    }, $class;

    return $self;
}

sub _create_ehr($self) {
    return {
        "_type"             =>  "EHR_STATUS",
        "archetype_node_id" =>  "openEHR-EHR-EHR_STATUS.generic.v1",
        "name"              =>  {},
        "subject"           =>  {
            "external_ref"      =>  {
                "id"                    =>  {
                    "_type"                 =>  "GENERIC_ID",
                    "scheme"                =>  "nhs_number"
                },
                "namespace" =>  "EHR",
                "type"      =>  "PERSON"
            }
        },
        "is_modifiable" =>  JSON::MaybeXS::true,
        "is_queryable"  =>  JSON::MaybeXS::true
    };
}

sub con_test($self) {
    my $ehrbase =   $self->{ehrbase};
    my $req_url =   "$ehrbase/ehrbase/rest/openehr/v1/definition/template/adl1.4";

    my $request =   GET(
        $req_url,
        'Accept' => 'application/json',
        'Prefer' => 'return=minimal'
    );

    my $ua  =   $self->{agent};
    my $res =   $ua->request($request);

    return  {
        code    =>  $res->code(),
        content =>  $res->content()
    };
}

sub create_ehr($self,$uuid,$name,$nhsnumber) {
    my $ehrbase             =   $self->{ehrbase};
    my $req_url             =   "$ehrbase/ehrbase/rest/openehr/v1/ehr/$uuid";
    my $create_ehr_script   =   $self->_create_ehr();

    $create_ehr_script->{name}->{value}
        =   $name;
    $create_ehr_script->{subject}->{external_ref}->{id}->{value}
        =   $nhsnumber;

    my $json_script         =   encode_json($create_ehr_script);

    say STDERR "Creation script: $json_script";
    say STDERR "URL: $req_url";

    my $request = PUT(
        $req_url,
        'Accept'                =>  'application/json',
        'Content-Type'          =>  'application/json',
        'PREFER'                =>  'representation=minimal',
        Content                 =>  $json_script
    );

    my $res = $self->{agent}->request($request);

    if ($res->code != 204)  {
        die "Failure creating patient!\n".Dumper($res->decoded_content());
    }

    my ($uuid_extract) = $res->header('ETag') =~ m/^"(.*)"$/;
    
    return {
        code    =>  $res->code(),
        content =>  uc($uuid_extract)
    };
}

sub check_ehr_exists($self,$nhs) {
    my $ehrbase =   $self->{ehrbase};
    my $req_url =   "$ehrbase/ehrbase/rest/openehr/v1/ehr"
    .   "?subject_id=$nhs"
    .   "&subject_namespace=EHR";

    my $request = GET(
        $req_url,
        'Accept'        =>  'application/json',
        'Content-Type'  =>  'application/json',
        Content         =>  ''
    );
 
    my $ua              =   $self->{agent};
    my $res             =   $ua->request($request);
    my $return_code     =   $res->code();

    if ($return_code == 200) {
        return {
            code    =>  $return_code,
            content =>  decode_json($res->decoded_content())
        };
    }
    elsif ($return_code == 404)   {
        return {
            code    =>  $return_code,
            content =>  undef
        };
    }
    else {
        
        return {
            code    =>  $return_code,
            content =>  "non captured response: $req_url ($return_code)"
        }
    }
}

sub send_template($self,$template) {
    my $ehrbase =   $self->{ehrbase};
    my $req_url =   "$ehrbase/ehrbase/rest/openehr/v1/definition/template/adl1.4";

    my $request =   POST(
        $req_url,
        'Accept'        => 'application/xml',
        'Content-Type'  => 'application/xml',
        'Prefer'        => 'return=minimal',
        Content         =>  $template
    );

    my $ua  = $self->{agent};
    my $res = $ua->request($request);

    return {
        code    =>  $res->code(),
        content =>  undef
    };
}
