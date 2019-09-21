FROM debian:stable-slim

LABEL maintainer="Rostyslav Fridman <rostyslav_fridman@epam.com>"

RUN DEBIAN_FRONTEND=noninteractive apt-get update -y \
    && DEBIAN_FRONTEND=noninteractive apt-get -y -q install \
        apt-utils \
        apt-transport-https \
        ca-certificates \
        curl \
        jq \
    && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
    && DEBIAN_FRONTEND=noninteractive apt-get autoremove -y \
    && DEBIAN_FRONTEND=noninteractive apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ADD scripts/sdn-controller.sh /opt/bin/sdn-controller.sh

CMD ["bash", "/opt/bin/sdn-controller.sh"]