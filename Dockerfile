FROM ubuntu:18.04

LABEL maintainer="Steve Horsfield <stevehorsfield@users.noreply.github.com>"
USER root

WORKDIR /

ENV TINI_VERSION=v0.18.0

RUN apt-get update \
    && apt-get install \
       -y --no-install-recommends \
       curl jq systemd ca-certificates netcat \
    && rm -rf /var/lib/apt/lists/* \
    && curl -L https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini -o /tini --silent --fail \
    && chmod u+x /tini

ENV JOURNAL_LOCATION="/var/log/journal"
ENV JOURNAL_CURSOR_TRACKING="/var/log/journal-shipper-cursor.pos"
ENV GRAYLOG_GELF_ADDRESS=some-gelf-logs.myorg.org
ENV GRAYLOG_GELF_PORT=1504
ENV GRAYLOG_ENVIRONMENT=missing

ADD send.sh /send.sh

ENTRYPOINT ["/tini", "/bin/bash", "--", "/send.sh"]