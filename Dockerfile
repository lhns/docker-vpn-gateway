FROM debian:13.1

RUN apt-get update \
 && apt-get install -y ca-certificates curl dnsutils gnupg iproute2 iptables jq procps \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
 && chmod a+r /etc/apt/keyrings/docker.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y docker-ce-cli

COPY elevate /
COPY docker-vpn-gateway.sh /

ENV INTERVAL=30

CMD ["/docker-vpn-gateway.sh"]
