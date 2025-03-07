# docker-vpn-gateway

[![Build Workflow](https://github.com/lhns/docker-vpn-gateway/workflows/build/badge.svg)](https://github.com/lhns/docker-vpn-gateway/actions?query=workflow%3Abuild)
[![Release Notes](https://img.shields.io/github/release/lhns/docker-vpn-gateway.svg?maxAge=3600)](https://github.com/lhns/docker-vpn-gateway/releases/latest)
[![Apache License 2.0](https://img.shields.io/github/license/lhns/docker-vpn-gateway.svg?maxAge=3600)](https://www.apache.org/licenses/LICENSE-2.0)

Docker VPN Gateway is a Docker Swarm operator designed to route container traffic through a VPN container. By modifying the default gateway of all containers connected to a specified network, it ensures that their traffic is directed through the VPN container.

## Features

- **Automated Gateway Configuration:** Seamlessly sets the default gateway for containers to route traffic through the VPN.
- **Docker Swarm Compatibility:** Operates efficiently within a Docker Swarm environment.
- **Minimal Configuration:** Requires only essential environment variables for setup.

## Prerequisites

- **Docker Engine:** Ensure you have Docker installed.
- **Docker Swarm:** Initialize Docker Swarm on your system. [Swarm Init Guide](https://docs.docker.com/engine/swarm/swarm-tutorial/create-swarm/)

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

### In this configuration

- **Networks:**
  - `arr`: An internal network where application containers reside. Marking it as `internal: true` ensures these containers cannot access the internet directly.
  - `internet`: An external network providing internet access.
- **Services:**
  - **gluetun:** The VPN container connected to both `arr` and `internet` networks. It requires internet access to establish the VPN connection and must be reachable by application containers.
  - **add-vpn-gateway:** The service that configures other containers to route their traffic through the VPN. It runs in privileged mode to modify network settings.
  - **sabnzbd:** An example application container connected only to the `arr` network, ensuring its traffic is routed through the VPN.

### Note on Network Naming

Docker Compose and Docker Swarm have specific naming conventions:
- When deploying a stack named `arr`, Docker automatically prefixes resources with the stack name. For example, a network defined as `arr` in the Compose file will be named `arr_arr` in Docker. This is why the `CLIENT_NETWORK` is set to `arr_arr` to match Docker's actual network name.
- If you define a network as external and it already exists, Docker uses the provided name without modification.

### Deploy the stack

```sh
docker stack deploy -c docker-compose.yml arr
```

## Privileged Mode in Docker Swarm

Certain operations, such as configuring network settings within containers, require elevated privileges. In Docker, this is typically achieved by running containers in "privileged" mode. However, Docker Swarm does not natively support the --privileged flag when deploying services. Attempts to use this flag in a Swarm deployment result in warnings. This limitation poses challenges for services that require privileged access to the host system.

### Workarounds: `elevate` Command and `swarm-launcher`

To address the lack of native privileged mode support in Docker Swarm, two primary methods are employed:
- The `elevate` Command is a custom script designed specifically for the VPN Gateway container. When executed, it performs the following actions:
  - **Direct Docker Daemon Interaction:** Utilizes the Docker socket (`/var/run/docker.sock`) to communicate directly with the Docker daemon.
  - **Launches a Privileged Container:** Initiates a new instance of the VPN Gateway as a privileged container outside the Swarm orchestration. This allows the service to perform necessary privileged operations without being constrained by Swarm's limitations.
  - By using the `elevate` command, the VPN Gateway can attain the required privileges to modify network configurations or access specific host resources.
- [swarm-launcher](https://github.com/ix-ai/swarm-launcher) is a Docker image designed to facilitate the launch of containers with options typically unavailable in Swarm mode, including privileged mode. It operates by:
  - **Accessing the Docker Socket:** Interacts directly with the Docker daemon via the Docker socket.
  - **Deploying Privileged Containers:** Starts containers with the necessary privileges outside the constraints of Swarm's service definitions.
  - This approach ensures that services requiring elevated privileges can function correctly within a Swarm-managed environment.

**Note:** The privileged containers launched by the elevate command and swarm-launcher are not part of the Swarm but are managed by their respective launchers. This distinction is crucial for understanding their lifecycle and management.

**Security Considerations:**
Granting privileged access to containers can pose security risks. It's essential to ensure that only trusted services are granted such privileges and that access to the Docker socket is securely managed to prevent unauthorized operations.

## Configuration Options

- `CLIENT_NETWORK`: The Docker network to which your target containers are connected.
- `TUN_CONTAINER_NAME`: The name of the VPN container with the active tun interface.

## Usage Example

Consider a scenario where you have a VPN container named `gluetun` and a network named `arr`. Your `docker-compose.yml` would be as shown above.

This setup ensures that all containers connected to the `arr` network route their traffic through the `gluetun` VPN container.

**Note:** If you attach additional networks (e.g., for services like Traefik) to your application containers, ensure these networks are also marked as `internal: true`. This precaution prevents containers from accessing the internet directly before the VPN gateway configures their routes.

## Troubleshooting & FAQs

### Q1: Containers aren't routing traffic through the VPN.

Ensure the `CLIENT_NETWORK` and `TUN_CONTAINER_NAME` environment variables are correctly set.
Verify that the VPN container is active and functioning properly.
Check Docker Swarm's status to ensure it's running without issues.

### Q2: How can I confirm that container traffic is routed through the VPN?

Inside a container connected to the `CLIENT_NETWORK`, check the default gateway:
```sh
ip route
```
The default gateway should point to the VPN container's IP address.

## Contributing

We welcome contributions! Please fork the repository and submit a pull request with your changes.

## License

This project uses the Apache 2.0 License. See the file called LICENSE.
