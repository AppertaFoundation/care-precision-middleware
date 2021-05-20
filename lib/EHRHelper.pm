package EHRHelper;

# TODO - accept a UA and use that

# Internal perl modules (core)
use v5.24;

# Internal perl modules (core,recommended)
use utf8;
use experimental qw(signatures);

# Debug/Reporting modules
use Carp qw(cluck longmess shortmess);
use Data::Dumper;

use Mojo::UserAgent;
use Path::Tiny;
use List::Util qw(pairmap);
use Encode;

# Some JSON hackery
use JSON::MaybeXS ':all';

# Primary code block
sub new($class, $template_path, $dbh, $set_debug = 0, $ehrbase = 'http://localhost:8080') {
    my $debug = 0;
    if ($set_debug) { $debug = 1 }

    my $self = bless {
        agent         => Mojo::UserAgent->new,
        ehrbase       => $ehrbase,
        dbh           => $dbh,
        debug         => $debug,
        template_path => $template_path,
    }, $class;

    $self->init_ehrbase;

    return $self;
}

sub init_ehrbase($self) {
    while (my $query = $self->_con_test()) {
        if ($query->{code} == 200) {
            my $template_list = $query->{content};
            if (scalar(@{$template_list}) > 0) {
                say STDERR "Templates already detected";
                say STDERR Dumper($template_list);
                last;
            }

            my $template_raw = path($self->{template_path} . '/full-template.xml')->slurp;
            my $response     = $self->send_template($template_raw);

            if ($response->{code} == 204) {
                say STDERR "Template successfully uploaded!";
                last;
            }
            else {
                say STDERR "Critical error uploading template! " . $response->{code};
                die;
            }
        }
        elsif ($query->{code} == 500) {
            sleep 5;
        }
    }
    foreach my $patient_ehrid_raw ($self->{dbh}->return_col('uuid')->@*) {
        my $patient_ehrid = $patient_ehrid_raw->[0];

        my $patient = $self->{dbh}->return_row(
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
        my $res                 =   $self->check_ehr_exists($patient_nhsnumber);

        if ($res->{code} != 200) {
            my $create_record = $self->create_ehr(
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

sub _con_test($self) {
    my $ehrbase = $self->{ehrbase};
    my $req_url = "$ehrbase/ehrbase/rest/openehr/v1/definition/template/adl1.4";

    say STDERR "con test: $req_url";
    my $res = $self->{agent}->get($req_url => {
        'Accept' => 'application/json'
    })->result;

    die "Did it wrong" if $res->code == 400;

    return  {
        code    =>  $res->code,
        content =>  $res->json,
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

    my $res = $self->{agent}->put($req_url, json => $create_ehr_script)->result;

    if ($res->code != 204)  {
        die "Failure creating patient!\n".Dumper($res->decoded_content());
    }

    my ($uuid_extract) = $res->headers->etag =~ m/^"(.*)"$/;

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

    my $res = $self->{agent}->get($req_url => {
        'Accept'        =>  'application/json',
        'Content-Type'  =>  'application/json',
    })->result;
    my $return_code = $res->code;

    if ($return_code == 200) {
        return {
            code    =>  $return_code,
            content =>  $res->json,
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
    my $ehrbase = $self->{ehrbase};
    my $req_url = "$ehrbase/ehrbase/rest/openehr/v1/definition/template/adl1.4";

    my $res = $self->{agent}->post($req_url, { 'Content-Type' => 'application/xml' }, encode_utf8($template))->result;

    return {
        code    =>  $res->code,
        content =>  $res->body
    };
}

sub get_compositions($self, $patient_uuid) {
    if (!defined $patient_uuid) {
        die "No uuid passed to function";
    }

    my $valid_uuid = $self->{dbh}->return_single_cell('uuid',$patient_uuid,'uuid');

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

        my $res = $self->{agent}->post($req_url, json => $query)->result;
        if ($res->code != 200)  {
            if ($res->code == 404) {
                print STDERR "Patient $patient_uuid not found";
                die;
            }

            print STDERR "Invalid AQL query - " . $query->{q} . "(". $res->code . ")";
            die;
        }

        my $raw_obj = $res->json;
        $raw_obj->{rows}
    };

    say STDERR "No compositions: $patient_uuid" and return if not @$composition_objs;

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
        my $req_url = "$ehrbase/ehrbase/rest/openehr/v1/ehr/$ehrid/composition/$compositionid";
        my $res = $self->{agent}->get($req_url, {
            'Accept'       => 'application/xml',
            'Content-Type' => 'application/json',
        }, json => $query)->result;

        if ($res->code != 200)  {
            print STDERR "Invalid AQL query";
            die;
        }
        $res->body;
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

        my $denwis_node = $xml->$get_node_with_name('DENWIS');

        if ($denwis_node) {
            my $assessment = {
                denwis => {
                    q1_breathing => {
                        pairmap { $a => $denwis_node->$dig_into_xml_for({ name => "Q1 Breathing" }, $b) }
                            ordinal => 'value > value',
                            value   => 'symbol > value',
                            code    => 'code_string',
                    },
                    q2_circulation => {
                        pairmap { $a => $denwis_node->$dig_into_xml_for({ name => "Q2 Circulation" }, $b) }
                            ordinal => 'value > value',
                            value   => 'symbol > value',
                            code    => 'code_string',
                    },
                    q3_temperature => {
                        pairmap { $a => $denwis_node->$dig_into_xml_for({ name => "Q3 Temperature" }, $b) }
                            ordinal => 'value > value',
                            value   => 'symbol > value',
                            code    => 'code_string',
                    },
                    q4_mentation => {
                        pairmap { $a => $denwis_node->$dig_into_xml_for({ name => "Q4 Mentation" }, $b) }
                            ordinal => 'value > value',
                            value   => 'symbol > value',
                            code    => 'code_string',
                    },
                    q5_agitation => {
                        pairmap { $a => $denwis_node->$dig_into_xml_for({ name => "Q5 Agitation" }, $b) }
                            ordinal => 'value > value',
                            value   => 'symbol > value',
                            code    => 'code_string',
                    },
                    q6_pain => {
                        pairmap { $a => $denwis_node->$dig_into_xml_for({ name => "Q6 Pain" }, $b) }
                            ordinal => 'value > value',
                            value   => 'symbol > value',
                            code    => 'code_string',
                    },
                    q7_trajectory => {
                        pairmap { $a => $denwis_node->$dig_into_xml_for({ name => "Q7 Trajectory" }, $b) }
                            ordinal => 'value > value',
                            value   => 'symbol > value',
                            code    => 'code_string',
                    },
                    q8_patient_subjective => {
                        pairmap { $a => $denwis_node->$dig_into_xml_for({ name => "Q8 Patient subjective" }, $b) }
                            ordinal => 'value > value',
                            value   => 'symbol > value',
                            code    => 'code_string',
                    },
                    q9_nurse_subjective => {
                        pairmap { $a => $denwis_node->$dig_into_xml_for({ name => "q9_nurse_subjective" }, $b) }
                            ordinal => 'value > value',
                            value   => 'symbol > value',
                            code    => 'code_string',
                    },
                    q_10_other_comment => $denwis_node->$dig_into_xml_for({ name => "Q 10 Other comment" }, 'value > value'),
                    total_score => $denwis_node->$dig_into_xml_for({ name => "Total score" }, 'magnitude'),
                }
            };

            push @assessments, $assessment;
        }
    }

    return @assessments;
}

sub store_composition($self, $patient_uuid, $composition) {
    my $req_url = $self->{ehrbase} . "/ehrbase/rest/openehr/v1/ehr/$patient_uuid/composition";

    my $response = $self->{agent}->post($req_url, {
        'Content-Type' => 'application/xml',
        Accept => '*/*'
    }, encode_utf8($composition))->result;

    if ($response->code != 204) {
        die $response->body;
    }
    return;
}
1;
