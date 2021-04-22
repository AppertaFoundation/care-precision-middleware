package EHRHelper;

# TODO - accept a UA and use that

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

use DBHelper;

my $dbh = DBHelper->new;

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

sub get_compositions($self, $patient_uuid) {
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
        my $ehrbase =   $self->{ehrbase};
        my $req_url =   "$ehrbase/ehrbase/rest/openehr/v1/query/aql";
        my $query = {
            'q'    =>  "SELECT c/uid/value FROM EHR e [ehr_id/value = '$patient_uuid'] CONTAINS COMPOSITION c"
        };

        my $request = POST(
            $req_url,
            'Accept'        =>  'application/json',
            'Content-Type'  =>  'application/json',
            Content         =>  encode_json($query)
        );

        my $ua = LWP::UserAgent->new();
        my $res = $ua->request($request);

        if ($res->code != 200)  {
            if ($res->code == 404) {
                print STDERR "Patient $patient_uuid not found";
                die;
            }

            print STDERR "Invalid AQL query - " . $query->{q} . "(". $res->code . ")";
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

        my $ehrbase =   $self->{ehrbase};
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
        my $nodes = $dom->find('name > value')->grep(sub { $_->text eq $name });

        if (wantarray) {
            return $nodes->map( sub { $_->parent->parent } );
        }
        else {
            if ($nodes->size) {
                return $nodes->first->parent->parent;
            }
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
        my $xml = Mojo::DOM->with_roles('+PrettyPrinter')->new($xml_string);

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

        my $covid_node = $get_node_with_name->($xml, 'Covid');

        if ($covid_node) {
            my $assessment = {};
            if (my $symptoms = $covid_node->$dig_into_xml_for({ name => "Covid symptoms" })) {
                $assessment->{date_of_onset_of_first_symptoms} = $symptoms->$dig_into_xml_for(
                    { name => "Date of onset of first symptoms" },
                    'value[xsi\:type]'
                );

                $assessment->{specific_symptom_sign} = [
                    map { {
                        value => $_->$dig_into_xml_for('value > value'),
                        code => $_->$dig_into_xml_for('code_string')
                    } }
                    $symptoms->$dig_into_xml_for({ name => "Symptom or sign name"})
                ];
            }

            if (my $exposure = $covid_node->$dig_into_xml_for({ name => "Covid-19 exposure" })) {
                if (my $struct = $exposure->$dig_into_xml_for({ name => "Care setting has confirmed Covid-19" })) {
                    $assessment->{covid_19_exposure}->{care_setting_has_confirmed_covid_19} = {
                        value => $struct->$dig_into_xml_for('value > value'),
                        code => $struct->$dig_into_xml_for('code_string')
                    }
                }
            }

            if (my $exposure = $covid_node->$dig_into_xml_for({ name => "Covid-19 exposure" })) {
                if (my $struct = $exposure->$dig_into_xml_for({ name => "Contact with suspected/confirmed Covid-19" })) {
                    $assessment->{covid_19_exposure}->{contact_with_suspected_confirmed_covid_19} = {
                        value => $struct->$dig_into_xml_for('value > value'),
                        code => $struct->$dig_into_xml_for('code_string')
                    }
                }
            }

            if (my $notes = $covid_node->$dig_into_xml_for({ name => "Covid notes" })) {
                $assessment->{covid_notes} = $notes->$dig_into_xml_for('value > value');
            }

            push @assessments, { covid => $assessment };
        }
    }

    return @assessments;
}

sub store_composition($self, $patient_uuid, $composition) {
    my $req_url = $self->{ehrbase} . "/ehrbase/rest/openehr/v1/ehr/$patient_uuid/composition";

    my $request = POST(
        $req_url, {
            'Content-Type'  =>  'application/xml',
            Accept          =>  '*/*'
        } => encode_utf8($composition)
    );
    my $response = $self->{agent}->request($request);

    if ($response->code != 204) {
        die $response->to_string;
    }
    return;
}
1;
