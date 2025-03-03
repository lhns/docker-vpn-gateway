# docker-vpn-gateway

[![Build Workflow](https://github.com/lhns/docker-vpn-gateway/workflows/build/badge.svg)](https://github.com/lhns/docker-vpn-gateway/actions?query=workflow%3Abuild)
[![Release Notes](https://img.shields.io/github/release/lhns/docker-vpn-gateway.svg?maxAge=3600)](https://github.com/lhns/docker-vpn-gateway/releases/latest)
[![Apache License 2.0](https://img.shields.io/github/license/lhns/docker-vpn-gateway.svg?maxAge=3600)](https://www.apache.org/licenses/LICENSE-2.0)

This docker swarm operator changes the default gateway of all containers connected to a specific network to go out the tun interface of a vpn container.

## Example

```yml
version: "3.8"

services:
  add-vpn-gateway:
    image: ghcr.io/lhns/vpn-gateway:0.2.2
    command: /elevate
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:rw
    environment:
      CLIENT_NETWORK: arr_arr
      TUN_CONTAINER_NAME: gluetun-gluetun-1
    deploy:
      mode: global
  gluetun-launcher:
    image: ixdotai/swarm-launcher:v0.20.4
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:rw
    environment:
      LAUNCH_IMAGE: qmcgaw/gluetun
      LAUNCH_PULL: 'true'
      LAUNCH_PROJECT_NAME: 'gluetun'
      LAUNCH_SERVICE_NAME: 'gluetun'
      LAUNCH_CAP_ADD: 'NET_ADMIN'
      LAUNCH_ENVIRONMENTS: >-
        VPN_TYPE=openvpn
        UPDATER_PERIOD=24h
      LAUNCH_VOLUMES: >-
        /path/to/gluetun:/gluetun
      LAUNCH_EXT_NETWORKS: >-
        arr_internet
        arr_arr
    networks:
      - internet
  sabnzbd:
    image: lscr.io/linuxserver/sabnzbd:latest
    networks:
      - arr

networks:
  internet:
    driver: overlay
    attachable: true
  arr:
    driver: overlay
    internal: true
    attachable: true
```

## License

This project uses the Apache 2.0 License. See the file called LICENSE.
