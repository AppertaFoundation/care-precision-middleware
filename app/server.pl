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
use Data::Search;
use DateTime;
use XML::TreeBuilder;
use Path::Tiny;
use Template;
use JSON::Pointer;

use Mojo::UserAgent;
use LWP::UserAgent;
use HTTP::Request;

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
    patient_db  =>  {},
    handler     =>  {},
    helper      =>  {
        'days_of_week'      =>  [qw(Mon Tue Wed Thu Fri Sat Sun)],
        'months_of_year'    =>  [qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)],
    },
    compose     =>  {},
    uuids       =>  {}
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
my $api_hostname        =   $ENV{FRONTEND_HOSTNAME} or die "set FRONTEND_HOSTNAME";
my $api_hostname_cookie =   $ENV{FRONTEND_HOSTNAME} =~ s/.+\././r;

my $ehrbase             =   'http://127.0.0.1:8002';
#my $ehrbase             =   'http://127.0.0.1:6767';

my $create_ehr_body = {
    "_type"             =>  "EHR_STATUS",
    "archetype_node_id" =>  "openEHR-EHR-EHR_STATUS.generic.v1",
    "name"              =>  {
        "value" =>  "EHR Status"
    },
    "subject"           =>  {
        "external_ref"      =>  {
        "id"                    =>  {
            "_type"                 =>  "GENERIC_ID",
            "value"                 =>  "nhs_number",
            "scheme"                =>  "id_scheme"
        },
        "namespace" =>  "nhs_number",
        "type"      =>  "PERSON"
        }
    },
    "is_modifiable" =>  JSON::MaybeXS::true,
    "is_queryable"  =>  JSON::MaybeXS::true
};

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

            my $assessment = $payload->[1];
            my $patient_uuid = $assessment->{situation}->{uuid};
            my $patient = $global->{uuids}->{$patient_uuid};

            make_up_score( $assessment );
            my $summarised = summarise_composed_assessment( compose_assessments ( $patient, $assessment ) );

            $packet->{response}->code(200);
            $packet->{response}->header('Content-Type' => 'application/json');
            $packet->{response}->content(encode_json($summarised));

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
                (ref($payload) eq 'ARRAY')
                &&
                (scalar(@{$payload}) == 2)
#                &&
#                (ref($payload->[0]) eq 'HASH')
#                &&
#                (ref($payload->[1]) eq 'HASH')
#                &&
#                ($payload->[0]->{templateid})
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
                || !$passed_objects->[1] 
                || ref($passed_objects->[1]) ne 'HASH'
            ) {
                $frontend_response->content("Invalid request");
                $frontend_response->code(400);
                $kernel->yield('finalize', $frontend_response);
                return;
            }

            # We have a valid templateid request lets proceed with creating a composition!
            my $patient_uuid = $passed_objects->[1]->{header}->{uuid};

            # Create a place to put everything we need for ease and clarity
            my $uuid = $uuid->to_string($uuid->create());
            my $composition_obj =   {
                uuid    =>  $uuid,
                #base    =>  join('',read_file('composition.xml')),
                input   =>  $passed_objects
            };

            my $xml_transformation = sub {
                my $big_href = shift->{input};
                my $tt2 = Template->new({
                    ENCODING => 'utf8'
                });

                $big_href->[1]->{header}->{start_time} = DateTime->now->strftime('%Y-%m-%dT%H:%M:%SZ');

                my $json_path = sub { JSON::Pointer->get($big_href, $_[0]) };

                $tt2->process('template.xml', { json_path => $json_path }, \my $xml);
                return $xml;
            };

            $composition_obj->{output}  =   $xml_transformation->($composition_obj);

            my $ua = Mojo::UserAgent->new;

            my $req_url = "$ehrbase/ehrbase/rest/openehr/v1/ehr/d4ac93a7-4380-46a6-9cb3-49915381a94a/composition";

            my $tx = $ua->post($req_url, {
                    'Content-Type' => 'application/xml',
                    Accept => '*/*'
                } => encode_utf8($composition_obj->{output})
            );
            my $response = $tx->res;
            warn $response->code;

            # Finally return the XML file so we can see the results
            $frontend_response->header('Content-Type' => 'application/xml');
            $frontend_response->content($composition_obj->{base});
            $frontend_response->code(201);
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

            my $datetime = DateTime->now;

            $kernel->alias_set($heap->{myid});
            $kernel->post('service::main','register_handler',$heap->{myid});

            my $patient_list = decode_json(path('patients.json')->slurp);

            my @commit_list;

            # Simplify names, add assessments and digitize date of birth
            MAIN: foreach my $patient (@{$patient_list->{entry}}) {
                $patient->{_compositions} = [];

                my $name_res    =   $patient->{resource}->{name};
                my $name_use    =   [];

                foreach my $oldname (@{$name_res})  {
                    my $new_name = [
                        $oldname->{prefix}->[0] || '',
                        $oldname->{given}->[0] || '',
                        $oldname->{family} || ''
                    ];

                    if ($oldname->{use} && $oldname->{use} eq 'official') {
                        $name_use = $new_name;
                    }
                    else {
                        push @{$patient->{resource}->{name_other}},$new_name;
                    }
                }

                # Add the full name as the first name_other
                push @{$patient->{resource}->{name_other}},$name_use;
                # Overwrite the old style name with a normal one
                $patient->{resource}->{name} = join(' ',@{$name_use});

                # Move the nhs-number to make it easier to search
                $patient->{resource}->{nhsnumber}   = do {
                    my $return;
                    foreach my $id (@{$patient->{resource}->{identifier}}) {
                        if (
                            defined $id->{'system'} 
                            && $id->{'system'} eq 'https://fhir.nhs.uk/Id/nhs-number'
                        )  {
                            $return = $id->{'value'};
                        }
                    }
                    $return
                };

                # If there is no nhs number we do not want it
                if (!$patient->{resource}->{nhsnumber}) {
                    next MAIN;
                }

                my $patient_exist = do {
                    my $nhs = $patient->{resource}->{nhsnumber}||0;
                    my $req_url = "$ehrbase/ehrbase/rest/openehr/v1/ehr"
                    .   "?subject_id=$nhs"
                    .   "&subject_namespace=nhs_number";

                    my $request = GET($req_url);
                    $request->header('Accept' => 'application/json');
                    $request->header('Content-Type' => 'application/json');
                    $request->content();

                    my $ua = LWP::UserAgent->new();
                    my $res = $ua->request($request);

                    my $return;
                    if ($res->code == 200) {
                        my $content = decode_json($res->content());
                        $return = $content->{ehr_id}->{value};
                    }
                    elsif ($res->code == 404)   {
                        $return = undef;
                    }
                    else {
                        warn "non captured response: $req_url";
                    }

                    $return
                };

                # Adjust the base profile to add the correct name
                my $create_ehr_body_clone = dclone($create_ehr_body);
                $create_ehr_body_clone->{name}->{value}
                    =   $patient->{resource}->{name};
                $create_ehr_body_clone->{subject}->{external_ref}->{id}->{value}
                    =   $patient->{resource}->{nhsnumber};

                # my $req_url = "$ehrbase/ehrbase/rest/openehr/v1/ehr";

                $patient->{_uuid} = do {
                    my $req_url = "$ehrbase/ehrbase/rest/openehr/v1/ehr";

                    if (!defined $patient_exist) {
                        my $request = POST($req_url);
                        $request->header('Accept' => 'application/json');
                        $request->header('Content-Type' => 'application/json');
                        $request->content(encode_json($create_ehr_body_clone));

                        my $ua = LWP::UserAgent->new();
                        my $res = $ua->request($request);

                        if ($res->code != 204)  {
                            die "Failure creating patient!";
                        }

                        my ($uuid_extract) = $res->header('ETag') =~ m/^"(.*)"$/;
                        $patient_exist = $uuid_extract
                    }

                    $patient_exist
                };

                # Convert Date of birth to digitally calculable date
                my ($dob_year,$dob_month,$dob_day) = 
                    split(/\-/,$patient->{resource}->{'birthDate'});

                my $dob_obj = DateTime->new(
                    year       => $dob_year,
                    month      => $dob_month,
                    day        => $dob_day,
                    time_zone  => 'Europe/London',
                );

                $patient->{resource}->{'birthDateAsString'} =
                        join('-',$dob_year,$dob_month,$dob_day);

                $patient->{resource}->{'birthDate'} =
                    $dob_obj->epoch();

                push @commit_list,$patient;
            }

            foreach my $customer (@commit_list) {
                my $name        =   $customer->{resource}->{name};
                my $identifier  =   $customer->{_uuid};

                # Refactor the structure of the datasource, this would be a 
                # call to a specialist service in DITO Service_Client_UserDB
                my $datablock = {
                    'name'              =>  $name,
                    'id'                =>  $identifier,
                    'birthDate'         =>  $customer->{resource}->{'birthDate'},
                    'birthDateAsString' =>  $customer->{resource}->{'birthDateAsString'},
                    'gender'            =>  $customer->{resource}->{'gender'},
                    'identifier'        =>  $customer->{resource}->{'identifier'},
                    'location'          =>  'Bedroom',
                    'assessment'        =>  $customer->{assessment},
                    'nhsnumber'         =>  $customer->{resource}->{'nhsnumber'}
                };

                $global->{patient_db}->{$identifier} = $datablock;
                $global->{uuids}->{$identifier} = $customer;
            }

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
                filter_lte  => {
                    key     => $params->{filter_key},
                    value   => $params->{filter_max}
                },
                filter_gte  => {
                    key     => $params->{filter_key},
                    value   => $params->{filter_min}
                },
                filter      =>  {
                    key     =>  $params->{'filter_key'},
                    value   =>  $params->{'filter_value'}
                },
                search      =>  {
                    key     =>  $params->{'search_key'},
                    value   =>  $params->{'search_value'}
                },
                sort        =>  {
                    key     =>  $params->{'sort_key'},
                    value   =>  $params->{'sort_value'}
                },
                pagination  =>  {
                    key     =>  $params->{'pagination_key'},
                    value   =>  $params->{'pagination_value'}
                }
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
                $_->{assessment} = summarise_composed_assessment( compose_assessments( $global->{uuids}->{ $_->{id} } ) )
            }

            $response->content(encode_json($result));

            $kernel->yield('finalize', $response);
        },
        'search'            =>  sub {
            my ( $kernel, $heap, $session, $search_spec ) =
                @_[ KERNEL, HEAP, SESSION, ARG0 ];

            my $search_result   =   [];
            my $search_db       =   $global->{patient_db};

            foreach my $userid (keys %{$search_db}) {
                # Filter section
                if ($search_spec->{filter}->{enabled} == 1) {
                    my $search_key      =
                        $search_spec->{filter}->{key};
                    my $search_value    =
                        $search_spec->{filter}->{value};

                    my $search_db_ref   =
                        $search_db->{$userid}->{'assessment'};

                    if (
                        !defined $search_db_ref->{$search_key}
                        ||
                        !defined $search_db_ref->{$search_key}->{value}
                        ||
                        ($search_db_ref->{"$search_key"}->{value} ne $search_value)
                    ) {
                        next;
                    }
                }

                # Don't expect good results if you use a string field here
                if ($search_spec->{filter_lte}->{enabled}) {
                    my $search_key      =
                        $search_spec->{filter_lte}->{key};
                    my $search_value    =
                        $search_spec->{filter_lte}->{value};

                    my $search_db_ref   =
                        $search_db->{$userid}->{assessment};

                    if (
                        !defined $search_db_ref->{$search_key}
                        ||
                        !defined $search_db_ref->{$search_key}->{value}
                        ||
                        ($search_db_ref->{"$search_key"}->{value} > $search_value)
                    ) {
                        next;
                    }

                }

                if ($search_spec->{filter_gte}->{enabled}) {
                    my $search_key      =
                        $search_spec->{filter_gte}->{key};
                    my $search_value    =
                        $search_spec->{filter_gte}->{value};

                    my $search_db_ref   =
                        $search_db->{$userid}->{assessment};

                    if (
                        !defined $search_db_ref->{$search_key}
                        ||
                        !defined $search_db_ref->{$search_key}->{value}
                        ||
                        ($search_db_ref->{"$search_key"}->{value} < $search_value)
                    ) {
                        next;
                    }

                }

                # Search section
                if ($search_spec->{search}->{enabled} == 1) {
                    my $search_key      =
                        $search_spec->{search}->{key};
                    my $search_value    =
                        $search_spec->{search}->{value};

                    my $search_db_ref   =
                        $search_db->{$userid};

                    if (
                        $search_key eq 'combisearch'
                    )
                    {
                        my $search_match = 0;

                        if (
                            defined $search_db_ref->{nhsnumber}
                            &&
                            $search_db_ref->{nhsnumber} =~ m/\Q$search_value\E/i
                        )
                        {
                            $search_match = 1;
                        }
                        elsif (
                            defined $search_db_ref->{name}
                            &&
                            $search_db_ref->{name} =~ m/\Q$search_value\E/i
                        )
                        {
                            $search_match = 1;
                        }
                        elsif (
                            defined $search_db_ref->{location}
                            &&
                            $search_db_ref->{location} =~ m/\Q$search_value\E/i
                        )
                        {
                            $search_match = 1;
                        }
                        elsif (
                            defined $search_db_ref->{gender}
                            &&
                            $search_db_ref->{gender} =~ m/\Q$search_value\E/i
                        )
                        {
                            $search_match = 1;
                        }
                        elsif (
                            defined $search_db_ref->{birthdate}
                            &&
                            $search_db_ref->{birthdate} =~ m/\Q$search_value\E/i
                        )
                        {
                            $search_match = 1;
                        }

                        if ($search_match == 0) { 
                            next; 
                        }
                    }
                    elsif (
                        !defined $search_db_ref->{"$search_key"}
                        ||
                        ($search_db_ref->{"$search_key"} !~ m/\Q$search_value\E/i)
                    ) {
                        next;
                    }
                }

                push @{$search_result},$search_db->{$userid};
            }

            # Sort section
            if ($search_spec->{sort}->{enabled} == 1) {
                # key = sepsis/news2/name/birthdate
                # value = ASC/DESC
                if ($search_spec->{sort}->{key} eq 'birthdate') {
                    if ($search_spec->{sort}->{key} =~ m/ASC/i) {
                        @{$search_result} = reverse sort {
                            $a->{birthDate} cmp $b->{birthDate}
                        } @{$search_result}
                    }
                    else {
                        @{$search_result} = sort {
                            $a->{birthDate} cmp $b->{birthDate}
                        } @{$search_result}
                    }
                }
                elsif ($search_spec->{sort}->{key} =~ m/^(news2|sepsis|denwis)$/i) {
                    my $sort_key = $1;
                    if ($search_spec->{sort}->{key} =~ m/ASC/i) {
                        @{$search_result} = reverse sort {
                            $a->{$sort_key}->{value}->{value} cmp $b->{$sort_key}->{value}->{value}
                        } @{$search_result}
                    }
                    else {
                        @{$search_result} = sort {
                            ($a->{$sort_key}->{value}->{value} // 0) cmp ($b->{$sort_key}->{value}->{value} // 0)
                        } @{$search_result}
                    }
                }
            }

            # Pagination section
            # It's faster to redo the search and just send back chunks of what to send back
            # if we wanted to do this, we should just shove the details into the users
            # session and slice sections out based on the value of the page wanted
            if ($search_spec->{pagination}->{enabled} == 1) {
                # key = page size
                # value = page to show

                my $page_size       =   $search_spec->{pagination}->{key};
                my $page_index      =   $search_spec->{pagination}->{value};
                my $page_validated  =   1;

                if (
                    $page_size !~ m/^\d+$/
                    ||
                    $page_size < 0
                ) {
                    $page_validated = 0;
                }
                elsif (
                    $page_index !~ m/^\d+$/
                    ||
                    $page_size < 0
                ) {
                    $page_validated = 0;
                }

                my @chunks;
                if ($page_validated == 1) {
                    while (my @nibble = splice(@{$search_result},0,$page_size)) {
                        push @chunks,[@nibble];
                    }
                }

                if (
                    scalar(@chunks) >= $page_index
                    &&
                    scalar(@chunks) > 0
                    &&
                    defined $chunks[$page_index+1]
                ) {
                    return $chunks[$page_index+1];
                }
                else {
                    return [];
                }
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

sub compose_assessments {
    my $patient = shift;
    # Put a draft assesment in here. You can do multiple I suppose.
    my @extra = @_;

    my $composed = {};

    for my $composition (@extra, map { $_->{input} } $patient->{_compositions}->@*) {
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

    $composed->{$_}->{trend} //= 'first' for grep exists $composed->{$_}, qw/denwis news2/;

    return $composed;
}

sub summarise_composed_assessment {
    my $composed = shift;
    my $summary = {};

    if ($composed->{denwis}) {
        $summary->{denwis}->{value} = {
            value     =>  $composed->{denwis}->{total_score},
            trend     =>  $composed->{denwis}->{trend},
        }
    }

    if ($composed->{sepsis}) {
        $summary->{sepsis}->{value} = {
            value     =>  $composed->{sepsis}->{value},
        }
    }

    if ($composed->{news2}) {
        $summary->{news2}->{value}   =   do {
            # Just pick one of these at random
            my @clinical_risk = (
                {
                    'localizedDescriptions' => {
                        'en' => 'Ward-based response.'
                    },
                    'value' => 'at0057',
                    'label' => 'Low',
                    'localizedLabels' => {
                        'en' => 'Low'
                    }
                },
                {
                    'localizedLabels' => {
                        'en' => 'Low-medium'
                    },
                    'label' => 'Low-medium',
                    'value' => 'at0058',
                    'localizedDescriptions' => {
                        'en' => 'Urgent ward-based response.'
                    }
                },
                {
                    'localizedDescriptions' => {
                        'en' => 'Key threshold for urgent response.'
                    },
                    'value' => 'at0059',
                    'label' => 'Medium',
                    'localizedLabels' => {
                        'en' => 'Medium'
                    }
                },
                {
                    'value' => 'at0060',

                    'localizedDescriptions' => {
                        'en' => 'Urgent or emergency response.'
                    },
                    'localizedLabels' => {
                        'en' => 'High'
                    },
                    'label' => 'High'
                }
            );

            {
                value        => $composed->{news2}->{score},
                trend        => $composed->{news2}->{trend},
                clinicalRisk => $clinical_risk[rand @clinical_risk],
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

sub make_up_score {
    # just adds total_scores or whatever to the assessment
    my $assessment = shift;

    if ($assessment->{denwis}) {
        $assessment->{denwis}->{total_score} = (int rand 20) + 1;
    }

    if ($assessment->{sepsis}) {
        $assessment->{sepsis}->{value} = (qw/red green amber grey/)[rand 4];
    }

    if ($assessment->{news2}) {
        $assessment->{news2}->{score} = {
            "respiration_rate" => {
              "code" => "at0020",
              "value" => "21-24",
              "ordinal" => 2
            },
            "spo_scale_1" => {
              "code" => "at0031",
              "value" => "94-95",
              "ordinal" => 1
            },
            "air_or_oxygen" => {
              "code" => "at0036",
              "value" => "Air",
              "ordinal" => 0
            },
            "systolic_blood_pressure" => {
              "code" => "at0017",
              "value" => "≤90",
              "ordinal" => 3
            },
            "pulse" => {
              "code" => "at0013",
              "value" => "51-90",
              "ordinal" => 0
            },
            "consciousness" => {
              "code" => "at0024",
              "value" => "Alert",
              "ordinal" => 0
            },
            "temperature" => {
              "code" => "at0023",
              "value" => "35.1-36.0",
              "ordinal" => 1
            },
            "clinical_risk_category" => {
              "code" => "at0059",
              "value" => "Medium",
              "terminology" => "local"
            },
            "total_score" => (int rand 20) + 1,
        };
    }

    if ($assessment->{covid}) {
        # no idea
    }

    # It edits it in-place because I'm lazy - returning it is good practice
    return $assessment;
}
