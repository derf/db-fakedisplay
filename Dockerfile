# Copyright (C) 2020 Birte Kristina Friesel
#
# SPDX-License-Identifier: CC0-1.0

# docker build -t db-fakedisplay:latest --build-arg=dbf_version=$(git describe --dirty) .

FROM debian:buster-slim as files

ARG dbf_version=git

COPY index.pl /app/
COPY lib/ /app/lib/
COPY public/ /app/public/
COPY templates/ /app/templates/
COPY share/ /app/share/

WORKDIR /app

RUN ln -sf ../ext-templates/imprint.html.ep templates/imprint.html.ep \
	&& ln -sf ../ext-templates/privacy.html.ep templates/privacy.html.ep

RUN sed -i "s/version *=> *\$ENV{DBFAKEDISPLAY_VERSION}/version => '${dbf_version}'/" lib/DBInfoscreen.pm

FROM perl:5.40-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG APT_LISTCHANGES_FRONTEND=none

COPY cpanfile* /app/
WORKDIR /app

RUN apt-get update \
	&& apt-get -y --no-install-recommends install \
		ca-certificates \
		curl \
		gcc \
		libc6-dev \
		libdb5.3 \
		libdb5.3-dev \
		libssl3 \
		libssl-dev \
		libxml2 \
		libxml2-dev \
		make \
		zlib1g-dev \
	&& cpanm -n --no-man-pages --installdeps . \
	&& rm -rf ~/.cpanm \
	&& apt-get -y purge curl gcc libc6-dev libdb5.3-dev libssl-dev libxml2-dev make zlib1g-dev \
	&& apt-get -y autoremove \
	&& rm -rf /var/cache/apt/* /var/lib/apt/lists/*

COPY --from=files /app/ /app/

EXPOSE 8092

CMD ["hypnotoad", "-f", "index.pl"]
