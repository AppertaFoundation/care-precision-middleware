FROM perl:5.30

RUN cpanm -n \
    Cookie::Baker \
    Data::Dumper \
    Data::UUID \
    DateTime \
    File::Slurp \
    HTTP::Cookies \
    HTTP::Request::Common \
    HTTP::Status \
    JSON::MaybeXS \
    JSON::Pointer \
    Mojo::UserAgent \
    Mojo::DOM \
    Mojo::DOM::Role::PrettyPrinter \
    Path::Tiny \
    POE \
    POE::Component::Client::HTTP \
    POE::Component::Client::Keepalive \
    POE::Component::Server::SimpleHTTP \
    Storable Data::Search \
    Template \
    Test::POE::Client::TCP \
    Try::Tiny \
    URI \
    URI::QueryParam \
    LWP::UserAgent.pm 

COPY app /opt/C19

COPY build-asset/dumb-init_1.2.4_x86_64 /dumb-init
COPY build-asset/OpusVL-ACME-C19-0.001.tar.gz /root/OpusVL-ACME-C19-0.001.tar.gz
RUN cpanm /root/OpusVL-ACME-C19-0.001.tar.gz

RUN chmod +x /dumb-init

# FIXME, server.pl expects patients.json in PWD
RUN ln -s /opt/C19/patients.json /patients.json
RUN ln -s /opt/C19/full-template.xml /full-template.xml

WORKDIR /opt/C19

EXPOSE 18080

CMD [ "/dumb-init", "perl", "server.pl" ]
