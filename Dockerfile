FROM alpine:3.20

RUN apk add docker-cli jq

COPY docker-vpn-gateway.sh /

ENTRYPOINT ["/docker-vpn-gateway.sh"]