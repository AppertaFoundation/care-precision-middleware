use warnings; 
use strict; 
use Encode qw(is_utf8 encode decode); 
use feature 'say';

use LWP::UserAgent;
use HTTP::Request;

use URI;
use URI::QueryParam;
use HTTP::Request::Common;


my $c = do { 
    local $/,
    open(my $fh,"<","composition-news2-finished.xml");
    my $x=<$fh>;
    close($fh);
    $x 
}; 

            
my $req_url = 'http://ehrbase.c19.devmode.xyz/ehrbase/rest/openehr/v1/ehr/d4ac93a7-4380-46a6-9cb3-49915381a94a/composition';

           
            my $request = POST($req_url);
            $request->header('Accept' => '*/*');
            $request->header('Content-Type' => 'application/xml');
            $request->content($c);

            my $ua = LWP::UserAgent->new();
            my $res = $ua->request($request);
            warn $res->code();
