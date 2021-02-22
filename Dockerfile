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
    XML::TreeBuilder

COPY app /opt/C19

COPY build-asset/dumb-init /dumb-init

RUN chmod +x /dumb-init

# FIXME, server.pl expects patients.json in PWD
RUN ln -s /opt/C19/patients.json /patients.json
RUN ln -s /opt/C19/full-template.xml /full-template.xml

WORKDIR /

EXPOSE 18080

CMD [ "./dumb-init", "perl", "/opt/C19/server.pl" ]
