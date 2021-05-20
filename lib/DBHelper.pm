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
sub new($class, $db_path, $set_debug = 0) {
    $db_path->make_path;
    my $dbh = DBI->connect(
        'dbi:SQLite:dbname=' . $db_path . '/patient.db',
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

    my $create_table    =   $self->check_table_exist('patient');
    if ($create_table==0) { $self->init_schema() }

    return $self;
}

sub init_schema ($self) {
    # Double check the table exists and has content
    my $create_table    =   $self->check_table_exist('patient');

    if ($self->{debug}) {
        say STDERR "Table existed: $create_table"
    }

    if ($create_table == 0) {
        $self->init_data($create_table);
    }
    my $row_count = $self->row_count();

    if ($self->{debug}) { 
        say STDERR "Row count is now: $row_count";
    }
}

sub init_data($self,$create_table) {
    if ($create_table == 0) {
        $self->{dbh}->do(<<'SQL');
CREATE VIRTUAL TABLE patient USING fts4(
    uuid string PRIMARY KEY,
    name string NOT NULL,
    birth_date number NOT NULL,
    birth_date_string string NOT NULL,
    name_search string NOT NULL,
    gender string NOT NULL,
    location string default 'Bedroom',
    nhsnumber number NOT NULL
)
SQL
    }
    $self->{dbh}->do(<<SQL);
INSERT INTO patient (uuid,name,birth_date,birth_date_string,name_search,gender,location,nhsnumber)
VALUES
(
    'C7008950-79A8-4CE8-AC4E-975F1ACC7957',
    'Miss Praveen Dora',
    '19980313',
    '1998-03-13',
    'Praveen Dora',
    'female',
    'Bedroom',
    '9876543210'
),
(
    '89F0373B-CA53-41DF-8B54-0142EF3DDCD7',
    'Mr HoratioSamson',
    '19701016',
    '1970-10-16',
    'Horatio Samson',
    'male',
    'Bedroom',
    '9876543211'
),
(
    '0F878EC8-FECE-42DE-AE4E-F76BEFB902C2',
    'Mrs Elsie Mills-Samson',
    '19781201',
    '1978-12-01',
    'Elsie Mills-Samson',
    'male',
    'Bedroom',
    '9876512345'
),
(
    '220F7990-666E-4D64-9CBB-656051CE1E84',
    'Mrs Fredrica Smith',
    '19651213',
    '1965-12-13',
    'Fredrica Smith',
    'female',
    'Bedroom',
    '3333333333'
),
(
    '5F7C7670-419B-40E6-9596-AC39D670BF15',
    'Miss Kendra Fitzgerald',
    '19420528',
    '1942-05-28',
    'Kendra Fitzgerald',
    'female',
    'Bedroom',
    '9564963656'
),
(
    '4152DEC6-45E0-4EEE-A9DD-B233F1A07561',
    'Mrs Christine Taylor',
    '19230814',
    '1923-08-14',
    'Christine Taylor',
    'female',
    'Bedroom',
    '9933157213'
),
(
    'F6F1741D-BECA-4357-A23F-DD2B2FF934B9',
    'Miss Darlene Cunningham',
    '19980609',
    '1998-06-09',
    'Darlene Cunningham',
    'female',
    'Bedroom',
    '9712738531'
)
SQL
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

sub return_row_undef($self,$col_name,$col_value) {
    my $row_fetch = $self->return_row($col_name,$col_value);
    my $col_count = 0+(keys %{$row_fetch});
    if ($col_count == 0) { return undef }
    else { return $row_fetch }
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

sub find_user($self,$term,@hints) {
    # A $term will be searched on as a 'must be present'

    # Hints is not presently used! TODO -----------------
    # Hints will be used to apply to the resultant search response as a secondary filter
    # ordering results on the weight of the amount of matched hints, if no hints 
    # partially match then the results will be ordered a-z

    my $sql_str         =   "SELECT uuid,name FROM patient WHERE name LIKE ? ORDER BY name ASC";
    my $sth             =   $self->{dbh}->prepare($sql_str);

    $sth->execute(join('','%',$term,'%'));
    my $search_return   =   $sth->fetchall_hashref('uuid');

    my $row_count       =   keys %{$search_return};

    if ($row_count > 0)  {
        return $search_return;
    }
}

1;
