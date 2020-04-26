FROM perl:5.30-slim

ARG DEBIAN_FRONTEND=noninteractive

COPY cpanfile /app/cpanfile
WORKDIR /app

RUN apt-get update \
	&& apt-get -y --no-install-recommends install ca-certificates curl gcc git libc6-dev libdb5.3 libdb5.3-dev libssl1.1 libssl-dev libxml2 libxml2-dev make zlib1g-dev \
	&& cpanm -n --no-man-pages --installdeps . \
	&& rm -rf ~/.cpanm \
	&& apt-get -y purge curl gcc libc6-dev libdb5.3-dev libssl-dev libxml2-dev make zlib1g-dev \
	&& apt-get -y autoremove \
	&& apt-get -y clean \
	&& rm -rf /var/cache/apt/* /var/lib/apt/lists/*

COPY . /app

RUN ln -sf ../ext-templates/imprint.html.ep templates/imprint.html.ep \
	&& ln -sf ../ext-templates/privacy.html.ep templates/privacy.html.ep

EXPOSE 8092

CMD ["hypnotoad", "-f", "index.pl"]
