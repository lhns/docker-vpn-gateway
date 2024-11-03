FROM alpine:3.20

RUN apk add bash docker-cli jq

COPY elevate /
COPY docker-vpn-gateway.sh /

CMD ["/docker-vpn-gateway.sh"]
