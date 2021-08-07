package EHRHelper;

use v5.28;
use experimental 'signatures';
use Data::UUID;

sub new($class, $template_path, $dbh, $set_debug = 0, $ehrbase = '') {
    return bless {
        patients => {}
    }, $class;
}

sub create_ehr($self,$uuid,$name,$nhsnumber) {
    $self->{patients}->{$uuid} //= { name => $name, nhsnumber => $nhsnumber, compositions => [] };

    return { code => 200, content => Data::UUID->new->create_str };
}

sub check_ehr_exists($self,$nhs) {
    my ($ehr) = grep { $_->{nhsnumber} eq $nhs } values $self->{patients}->%*;

    return {
        code => ($ehr ? 200 : 404),
        content => $ehr
    };
}

sub get_compositions($self, $patient_uuid) {
    return $self->{patients}->{$patient_uuid}->{compositions};
}

sub store_composition($self, $patient_uuid, $composition) {
    push $self->{patients}->{$patient_uuid}->{compositions}->@*, $composition;
}

1;
