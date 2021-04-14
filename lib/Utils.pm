package Utils;

use v5.28;
use experimental 'signatures';

use Data::Dumper;
use JSON::MaybeXS;
use OpusVL::ACME::C19;
use DBHelper;
use EHRHelper;

my $api_hostname            =   $ENV{FRONTEND_HOSTNAME} or die "set FRONTEND_HOSTNAME";
my ($api_hostname_cookie)   =   $ENV{FRONTEND_HOSTNAME} =~ m/^.*?(\..*)$/;
my $ehrbase                 =   $ENV{EHRBASE_URI} or die "set EHRBASE_URI";

say STDERR "ehrbase URI: $ehrbase";


# news/db module started in LOUD mode, remove '1' to disable
my $dbh                     =   DBHelper->new(1);
my $ehrclient               =   EHRHelper->new(1,$ehrbase);
my $news2_calculator        =   OpusVL::ACME::C19->new(1);

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


sub compose_assessments($patient_uuid, @extra) {
    # Put a draft assesment in @extra. You can do multiple I suppose.

    my $composed = {};

    for my $composition (@extra, $ehrclient->get_compositions($patient_uuid)) {
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
            $news2_calculator->calculate_clinical_risk($assessment->{news2});
    }

    if ($assessment->{covid}) {
        # no idea
    }

    # It edits it in-place because I'm lazy - returning it is good practice
    return $assessment;
}

1;
