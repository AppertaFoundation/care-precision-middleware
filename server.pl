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
use DateTime;
use XML::TreeBuilder;

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

my $ehrbase             =   'http://192.168.101.3:8002';

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
                &&
                (ref($payload->[0]) eq 'HASH')
                &&
                (ref($payload->[1]) eq 'HASH')
                &&
                ($payload->[0]->{templateid})
             )  {
                my $request = GET($ehrbase.'/ehrbase/rest/openehr/v1/definition/template/adl1.4');
                $request->header('Accept' => 'application/json');

                $kernel->post(
                    'webclient',                    # posts to the 'ua' alias
                    'request',                      # posts to ua's 'request' state
                    'create_new_composition',       # which of our states will receive the response
                    $request,                       # an HTTP::Request object,
                    [$payload,$packet->{response}]  # a tag or object to pass things like a stash
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
            my ($kernel,$heap,$request_obj,$response_obj) = @_[KERNEL, HEAP, ARG0, ARG1];

            # Break out various bits and peices from the passed objects
            my $ehrbase_response    =   $response_obj->[0];
            my $frontend_request    =   $request_obj->[0];
            my $passed_objects      =   $request_obj->[1]->[0];
            my $frontend_response   =   $request_obj->[1]->[1];

            # Check the request templateid is present within the template list on ehrbase
            my $valid_template_test =   do  {
                my $templates_accessible    =   decode_json($ehrbase_response->decoded_content());
                my $template_requested      =   $passed_objects->[0]->{templateid};
                my $template_check_result   =   0;

                foreach my $availible_template (@{$templates_accessible}) {
                    if (
                        ($availible_template->{template_id} eq $template_requested)
                    )
                    {
                        $template_check_result = 1;
                        last;
                    }
                }
                $template_check_result
            };

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

            # Create a place to put everything we need for ease and clarity
            my $composition_obj =   {
                uuid    =>  $uuid->to_string($uuid->create()),
                base    =>  join('',read_file('composition.xml')),
                input   =>  $passed_objects->[1]
            };

            my $xml_transformation = sub {
                my $spec = $_[0] or die "No spec passed";

                # A place to stash our return
                my $return = {};

                # Process the XML file and get back something that can be adjusted
                my $tree = XML::TreeBuilder->new({ 'NoExpand' => 0, 'ErrorContext' => 0 });

                # Read in the initial base file
                $tree->parse($spec->{base});

                # Step 1 - Validate the input json - Should be a better test!
                # possible use knowledge of structure to recurse into any structure
                $return->{error} = 0;

                # Create a function in scalar for easier recursion
                my $recursive_structure_test = sub { warn "You should never see this" };
                $recursive_structure_test = sub {
                    # Every final leaf in this structure should end eiter in
                    # a single string or a hash with a set of strings with a key
                    # beginning with |
                    my ($object_reference)      =
                        @_;
                    my $object_type             =
                        ref($object_reference);

                    my $valid_structure = 0;

                    if ($object_type eq 'ARRAY') {
                        foreach my $array_child (@{$object_reference})   {
                            # There are no arrays that do not end in a hash leaf
                            # so all children here (if any) have to be hashes
                            $valid_structure = 
                                $recursive_structure_test->($array_child);
                        }
                    }
                    elsif ($object_type eq 'HASH') {
                        my $invalid_leaf_string = 0;
                        my $node_type           = 'leaf';
                        foreach my $hash_child (keys %{$object_reference})   {
                            if (ref($object_reference->{$hash_child})) {
                                $node_type          =
                                    'set';
                                $valid_structure    += 
                                    $recursive_structure_test->($object_reference->{$hash_child});
                            }
                            else {
                                if ($object_reference->{$hash_child} !~ m#^|#) {
                                    $invalid_leaf_string++;
                                }
                            }
                        }
                        if ($node_type eq 'leaf') {
                            if ($invalid_leaf_string) { return 1 }
                            else { return 0 }
                        }
                        # if its not a leaf we do not care about it
                        else { return 0 }
                    }

                    return $valid_structure;
                };

                # Step 1.1 Validate the json is full of known structures
                my $structure_test = do {
                    my $test_result = 0;
                    my $referece_point = $spec->{input};

                    # The initial level should be simply a list of keys
                    # A mixture of 
                    #   header(mandatory)
                    #   situation(optional)
                    #   background(optional)
                    #   denwis(optional)
                    #   sepsis(optional)
                    #   news2(optional)

                    if (ref($referece_point) eq 'HASH') {
                        $test_result = 1;
                    }
                    else {
                        $return->{error}    =   1;
                        push @{$return->{error_initial}},'Initial structure was not a HASH';
                        push @{$return->{errors}},'error_initial';
                    }

                    # Check the structure
                    if ($test_result == 1) {
                        my $valid_keys;
                        map { $valid_keys->{$_} = 1 } qw(header situation background denwis sepsis news2);

                        foreach my $level1key (%{$referece_point}) {
                            if (!$valid_keys->{$level1key}) {
                                push @{$return->{error_level1}},"Invalid level1 key found '$level1key'";
                                push @{$return->{errors}},'error_level1';
                                $test_result = 0;
                            }
                            else {
                                # Recurse into 
                                warn "Verification: ".$recursive_structure_test->($referece_point->{$level1key});
                            }
                        }
                    }
                };



                $structure_test
            };

            $composition_obj->{output}  =   $xml_transformation->($composition_obj);

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

            my $patient_list = decode_json(read_file('patients.json'));

            my @commit_list;

            # Simplify names, add assessments and digitize date of birth
            MAIN: foreach my $patient (@{$patient_list->{entry}}) {
                $patient->{_uuid} = $uuid->to_string($uuid->create());

                my $name_res    =   $patient->{resource}->{name};
                my $name_use    =   [];

                NAME: foreach my $oldname (@{$name_res})  {
                    my $new_name = [
                        $oldname->{prefix}->[0] || '',
                        $oldname->{given}->[0] || '',
                        $oldname->{family} || ''
                    ];

                    if ($oldname->{use} && $oldname->{use} eq 'official')  { 
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


                # Add example examinations
                $patient->{'assessment'} = {};

                # TODO Go make a query to ehrbase for all the latest versions
                # of these
                $patient->{'assessment'}->{denwis}->{value}   =   do {
                    my $return;
                    if (int(rand(2)) == 1) {
                        my @trends = qw(increasing decreasing first same);
                        my $selector = int(rand(scalar(@trends)));
                        $return = {
                            'value'     =>  int(rand(20)),
                            'trend'     =>  $trends[$selector],

                        };
                        $return  =  $return;
                    }
                    $return;
                };

                $patient->{'assessment'}->{covid}->{value}   =   do {
                    my $return;
                    if (int(rand(2)) == 1) {
                        my @flags = qw(red amber grey green);
                        my $selector = int(rand(scalar(@flags)));
                        $return->{suspected_covid_status} =
                                $flags[$selector];
                        $return->{date_isolation_due_to_end} =
                            '2020-11-10T22:39:31.826Z';
                        $return->{covid_test_request} =  {
                            'date'  =>  '2020-11-10T22:39:31.826Z',
                            'value' =>  'EXAMPLE TEXT'
                        }
                    }
                    $return;
                };

                $patient->{'assessment'}->{sepsis}->{value}   =   do {
                    my $return;
                    if (int(rand(2)) == 1) {
                        my @flags = qw(red amber grey);
                        my $selector = int(rand(scalar(@flags)));
                        $return = { value => $flags[$selector] };
                    }
                    $return;
                };

                $patient->{'assessment'}->{news2}->{value}   =   do {
                    my $return;
                    if (int(rand(2)) == 1) {
                        my @trends = qw(increasing decreasing first same);
                        my $selector = int(rand(scalar(@trends)));

                        # Look away.
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

                        $return = {
                            'value'     =>  int(rand(100)),
                            'trend'     =>  $trends[rand @trends],
                            'clinicalRisk' => $clinical_risk[rand @clinical_risk],
                        };
                        $return  =  $return;
                    }
                    $return;
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
                    'assessment'        =>  $customer->{'assessment'},
                    'nhsnumber'         =>  $customer->{resource}->{'nhsnumber'}
                };

                $global->{patient_db}->{"$identifier"} = $datablock;
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
