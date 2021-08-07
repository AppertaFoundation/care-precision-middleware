package Utils;

use v5.28;
use experimental 'signatures';

use Data::Dumper;
use JSON::MaybeXS;
use OpusVL::ACME::C19;
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

sub compose_assessments($self, $patient_uuid, @extra) {
    # Put a draft assesment in @extra. You can do multiple I suppose.

    my $composed = {};

    for my $composition (@extra, $self->{ehr_helper}->get_compositions($patient_uuid)) {
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
            'respiration_rate'          =>  $assessment->{news2}->{respirations}->{magnitude},
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
