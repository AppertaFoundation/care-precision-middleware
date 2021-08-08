package Utils;

use v5.28;
use experimental 'signatures';

use Mojo::File qw(curfile);
use Mojo::DOM;

use Data::UUID;
use File::Temp qw(tempfile);
use JSON::Pointer;
use JSON::MaybeXS;
use List::Util qw(pairmap);
use OpusVL::ACME::C19;
use Template;

use EHRHelper;

my $news2_calculator = OpusVL::ACME::C19->new(!! $ENV{DEBUG});

# Make sure ehrbase is synced with our patients
sub new ($class, %args) {
    my $self = {};
    $self->{template_path} = $args{template_path};
    $self->{dbh} = $args{dbh};
    $self->{ehr_helper} = EHRHelper->new($self->{template_path}, $self->{dbh}, 1);

    bless $self, $class;
}

# Yeah I know but it's easier ok
sub store_composition($self, $patient_uuid, $composition) {
    $self->{ehr_helper}->store_composition($patient_uuid, $composition);
}

sub composition_to_xml($self, $composition) {
    my $xml_transformation = sub {
        my $big_href = shift;
        my $tt2 = Template->new({ ENCODING => 'utf8', ABSOLUTE => 1 });

        my $json_path = sub { JSON::Pointer->get($big_href, $_[0]) };
        my $xml_tt = curfile->dirname->sibling('etc/composition.xml.tt2')->to_abs->to_string;

        $tt2->process($xml_tt, {
            json_path => $json_path,
            generate_uuid => sub { Data::UUID->new->create_str } },
        \my $xml) or die $tt2->error;

        return $xml;
    };

    my $xml_composition = $xml_transformation->($composition);

    # Write to /tmp for a log
    if ($ENV{DEBUG}) {
        my ($fh, $fn) = tempfile;
        binmode $fh, ':utf8';
        print $fh $xml_composition;
        say STDERR "Composition XML is in $fn";
    }

    return $xml_composition;
}

sub assessments_from_xml($self, $xml_composition) {
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
    my $xml = Mojo::DOM->with_roles('+PrettyPrinter')->new($xml_composition);

    my $news2_node = $get_node_with_name->($xml, 'NEWS2');

    if ($news2_node) {
        my $news2_score = $news2_node->$get_node_with_name('NEWS2 Score');
        $news2_score->remove;

        push @assessments, {
            'news2' => {
                'respirations' => $news2_node->$dig_into_xml_for({ name => 'Respirations'}, 'magnitude'),
                'spO2' => $news2_node->$dig_into_xml_for({ name => 'SpO₂'}, 'numerator'),
                'systolic' => $news2_node->$dig_into_xml_for({ name => 'Systolic' }, 'magnitude'),
                'diastolic' => $news2_node->$dig_into_xml_for({ name => 'Diastolic' }, 'magnitude'),
                'pulse' => $news2_node->$dig_into_xml_for({ name => 'Pulse Rate' }, 'magnitude'),
                'acvpu' => {
                    'code' => $news2_node->$dig_into_xml_for({ name => 'ACVPU' }, 'value code_string'),
                    'value' => $news2_node->$dig_into_xml_for({ name => 'ACVPU' }, 'value > value'),
                },
                'temperature' => $news2_node->$dig_into_xml_for({ name => 'Temperature' }, { name => 'Temperature' }, 'magnitude'),
                'inspired_oxygen' => {
                    'method_of_oxygen_delivery' => $news2_node->$dig_into_xml_for({ name => "Method of oxygen delivery" }, 'value value'),
                    'flow_rate' => $news2_node->$dig_into_xml_for({ name => "Flow rate" }, 'magnitude')
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

    return @assessments;
}

sub compose_assessments($self, $patient_uuid, @extra) {
    # Put a draft assessment in @extra. You can do multiple I suppose.

    my $composed = {};
    my @compositions = map { $self->assessments_from_xml($_) }
            $self->{ehr_helper}->get_compositions($patient_uuid)->@*;

    for my $composition (@extra, @compositions) {
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

        if ($composition->{covid}) {
            $composed->{covid} //= $composition->{covid}
        }
    }

    # Why write stuff like this >.> it could be made so much clearer just 
    # taking up a tiny bit more vertical height.... (comment by pgw)
    # [AD] If you don't like it, edit it
    $composed->{$_}->{trend} //= 'first' for grep exists $composed->{$_}, qw/denwis news2/;

    return $composed;
}

sub summarise_composed_assessment($self, $composed) {
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

sub fill_in_scores($self, $assessment) {
    # just adds total_scores or whatever to the assessment

    if ($assessment->{denwis}) {
        # 0 to 9
        $assessment->{denwis}->{total_score} = (int rand 10);
    }

    if ($assessment->{sepsis}) {
        $assessment->{sepsis}->{value} = (qw/red green amber grey/)[rand 4];
    }

    if ($assessment->{news2}) {
        my $news2_scoring = $news2_calculator->news2_calculate_score({
            'respiration_rate'          =>  $assessment->{news2}->{respiration_rate},
            'spo2_scale_1'              =>  $assessment->{news2}->{spO2},
            'pulse'                     =>  $assessment->{news2}->{pulse},
            'temperature'               =>  $assessment->{news2}->{temperature},
            'systolic_blood_pressure'   =>  $assessment->{news2}->{systolic},
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
        $assessment->{news2}->{score}->{clinical_risk_category} =
            $news2_calculator->calculate_clinical_risk($assessment->{news2});
    }

    if ($assessment->{covid}) {
        # no idea
    }

    # It edits it in-place because I'm lazy - returning it is good practice
    return $assessment;
}

1;
