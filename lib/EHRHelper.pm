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
use Encode;

# Some JSON hackery
use JSON::MaybeXS ':all';

my $EHRBASE = $ENV{EHRBASE_URI} or die "set EHRBASE_URI";

say STDERR "ehrbase URI: $EHRBASE";

# Primary code block
sub new($class, $template_path, $dbh, $set_debug = 0, $ehrbase = $EHRBASE) {
    my $debug = 0;
    if ($set_debug) { $debug = 1 }

    my $self = bless {
        agent         => Mojo::UserAgent->new,
        ehrbase       => $ehrbase,
        dbh           => $dbh,
        debug         => $debug,
        template_path => $template_path,
    }, $class;

    $self->_init_ehrbase;

    return $self;
}

sub _init_ehrbase($self) {
    while (my $query = $self->_con_test()) {
        if ($query->{code} == 200) {
            my $template_list = $query->{content};
            if (scalar(@{$template_list}) > 0) {
                say STDERR "Templates already detected";
                say STDERR Dumper($template_list);
                last;
            }

            my $template_raw = path($self->{template_path} . '/full-template.xml')->slurp;
            my $response     = $self->_send_template($template_raw);

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

=head2 create_ehr

    $uuid, $name, $nhs_number --> { code => $code, content => UUID }

Unclear what the returned UUID is in C<content>. Unclear what the purpose of
returning C<code> is.

Creates a patient record in EHRBase.

=cut

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

=head2 check_ehr_exists

    $nhsnumber --> { code => $code, content => $content }

If successful, C<content> contains a hashref from EHRBase. If not found,
C<content> is undef and C<code> is 404. Otherwise, C<content> is a fairly
useless string.

=cut

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

sub _send_template($self,$template) {
    my $ehrbase = $self->{ehrbase};
    my $req_url = "$ehrbase/ehrbase/rest/openehr/v1/definition/template/adl1.4";

    my $res = $self->{agent}->post($req_url, { 'Content-Type' => 'application/xml' }, encode_utf8($template))->result;

    return {
        code    =>  $res->code,
        content =>  $res->body
    };
}

=head2 get_compositions

    $uuid --> @compositions

With C<$uuid> from the patient database, return all stored compositions as XML.

=cut

sub get_compositions($self, $patient_uuid) {
    if (!defined $patient_uuid) {
        die "No uuid passed to function";
    }

    my $valid_uuid = $self->{dbh}->return_single_cell('uuid',$patient_uuid,'uuid');

    if (!$valid_uuid) {
        say STDERR "Invalid UUID passed to get_compositions UUID:($patient_uuid)";
        die;
    }

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

    return map { $retrieve_composition->($patient_uuid, $_->[0]) } @$composition_objs;
}

=head2 store_composition

    $uuid, $xml_composition --> Nil

Stores the XML in EHRBase. Presumably you have already got a way of creating
the XML?

=cut

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
