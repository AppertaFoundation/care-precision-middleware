use v5.20.0;
use JSON::Pointer;
use warnings;
use strict;
 
my $obj = 
[
    {
        blah => 'x',
        bleh => 'z'
    },
    {
        cunt => 'blah',
        cock => 'bleh'
    }    
];
 
say JSON::Pointer->get($obj, "/0/bleh");       ### $obj->{foo}
say JSON::Pointer->get($obj, "/1/cock"); ### $obj->{baz}{boo}[2]
