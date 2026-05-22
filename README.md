# docker-tailscale-gateway

[![Build Workflow](https://github.com/lhns/docker-vpn-gateway/workflows/build/badge.svg)](https://github.com/lhns/docker-vpn-gateway/actions?query=workflow%3Abuild)
[![Release Notes](https://img.shields.io/github/release/lhns/docker-vpn-gateway.svg?maxAge=3600)](https://github.com/lhns/docker-vpn-gateway/releases/latest)
[![Apache License 2.0](https://img.shields.io/github/license/lhns/docker-vpn-gateway.svg?maxAge=3600)](https://www.apache.org/licenses/LICENSE-2.0)

Docker Tailscale Gateway is a Docker Swarm operator designed to route container traffic through a Tailscale container. By adding routes to the Tailscale CGNAT range (100.64.0.0/10) in all containers connected to a specified network, it ensures that their traffic to Tailscale services is directed through the Tailscale container.

## Features

- **Automated Route Configuration:** Seamlessly adds routes to the Tailscale CGNAT range for containers to route traffic through the Tailscale container.
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
    image: decentralize/docker-tailscale-gateway
    command: /elevate
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:rw
    environment:
      CLIENT_NETWORK: arr_arr
      TAILSCALE_SERVICE_NAME: tailscale_tailscale
    deploy:
      mode: global
  tailscale:
    image: tailscale/tailscale
    environment:
      - TS_AUTHKEY=your-auth-key
      - TS_STATE_DIR=/var/lib/tailscale
    volumes:
      - /path/to/tailscale:/var/lib/tailscale
      - /dev/net/tun:/dev/net/tun:ro
    cap_add:
      - NET_ADMIN
    networks:
      - arr
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
  - **tailscale:** The Tailscale container connected to both `arr` and `internet` networks. It requires internet access to establish the Tailscale connection and must be reachable by application containers.
  - **add-vpn-gateway:** The service that configures other containers to route their traffic through the Tailscale container. It runs in privileged mode to modify network settings.
  - **sabnzbd:** An example application container connected only to the `arr` network, ensuring its traffic can reach Tailscale services.

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

### Workaround: `elevate` Command

To address the lack of native privileged mode support in Docker Swarm, the `elevate` command is employed:
- The `elevate` Command is a custom script designed specifically for the VPN Gateway container. When executed, it performs the following actions:
  - **Direct Docker Daemon Interaction:** Utilizes the Docker socket (`/var/run/docker.sock`) to communicate directly with the Docker daemon.
  - **Launches a Privileged Container:** Initiates a new instance of the VPN Gateway as a privileged container outside the Swarm orchestration. This allows the service to perform necessary privileged operations without being constrained by Swarm's limitations.
  - By using the `elevate` command, the VPN Gateway can attain the required privileges to modify network configurations or access specific host resources.

**Note:** The privileged containers launched by the elevate command are not part of the Swarm but are managed by the launcher. This distinction is crucial for understanding their lifecycle and management.

**Security Considerations:**
Granting privileged access to containers can pose security risks. It's essential to ensure that only trusted services are granted such privileges and that access to the Docker socket is securely managed to prevent unauthorized operations.

## Configuration Options

- `CLIENT_NETWORK`: The Docker network to which your target containers are connected.
- `TAILSCALE_SERVICE_NAME`: The name of the Tailscale Docker Swarm service (not the container name).

## Usage Example

Consider a scenario where you have a Tailscale service named `tailscale` and a network named `arr`. Your `docker-compose.yml` would be as shown above.

This setup ensures that all containers connected to the `arr` network can route their traffic to Tailscale services through the Tailscale container.

**Note:** If you attach additional networks (e.g., for services like Traefik) to your application containers, ensure these networks are also marked as `internal: true`. This precaution prevents containers from accessing the internet directly before the VPN gateway configures their routes.

## Troubleshooting & FAQs

### Q1: Containers aren't routing traffic through Tailscale.

Ensure the `CLIENT_NETWORK` and `TAILSCALE_SERVICE_NAME` environment variables are correctly set.
Verify that the Tailscale container is active and functioning properly.
Check Docker Swarm's status to ensure it's running without issues.

### Q2: How can I confirm that container traffic is routed through Tailscale?

Inside a container connected to the `CLIENT_NETWORK`, check the routes:
```sh
ip route
```
You should see a route to `100.64.0.0/10` (Tailscale CGNAT range) via the Tailscale container's IP address.

## Contributing

We welcome contributions! Please fork the repository and submit a pull request with your changes.

## License

This project uses the Apache 2.0 License. See the file called LICENSE.

## Acknowledgments

This project is a fork of [docker-vpn-gateway](https://github.com/lhns/docker-vpn-gateway).
