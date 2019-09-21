FROM debian:stable-slim

LABEL maintainer="Rostyslav Fridman <rostyslav_fridman@epam.com>"

ADD cni-driver.sh cni-driver.sh
ADD 10-custom.conf 10-custom.conf

CMD ["sh", "-c", "cp 10-custom.conf /etc/cni/net.d/10-custom.conf && \
    cp cni-driver.sh /opt/cni/bin/custom"]