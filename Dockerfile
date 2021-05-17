FROM perl:5.30

# Install OS level deps
RUN apt install libsqlite3-dev

# Copy the repository over to the installation directory
COPY . /opusvl

# Create var in the opusvl installation target directory (for db etc)
RUN mkdir -p /opusvl/var

# Install dumbinit
RUN cp -v /opusvl/build-asset/dumb-init_1.2.4_x86_64 /dumb-init \
    && chmod +x /dumb-init

# Swap to the workdir
WORKDIR /opusvl

# Tidy up a few things we do not want
RUN rm -Rf local .git old 

# Load in carton and any special 3rd party modules
RUN cpanm /opusvl/build-asset/OpusVL-ACME-C19-0.001.tar.gz
RUN cpanm --from "/opusvl/vendor/cache" --notest Carton

# FIXME, server.pl expects patients.json in PWD
RUN ln -s /opusvl/app/full-template.xml /full-template.xml

# Use Carton to install the required dependancies on the target container
RUN carton install --cached --deployment

CMD [ "/dumb-init", "perl", "-I/opusvl/local/lib/perl5", "/opusvl/app/careprotect.pl", "daemon" ]
