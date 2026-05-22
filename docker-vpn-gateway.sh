#!/bin/bash

set -o pipefail

TAILSCALE_ROUTE=100.64.0.0/10
TAILSCALE_DNS=100.100.100.100

get_container_name_for_service() {
  local service_name="$1"
  local container_name
  container_name=$(docker ps --filter "label=com.docker.swarm.service.name=$service_name" --filter "status=running" --format '{{.Names}}' | head -n 1)
  if [ -z "$container_name" ]; then
    echo "WARN: no running container found for service $service_name" >&2
    return 1
  fi
  echo "$container_name"
}

ns_rule() {
  local pid="$1"
  shift
  if nsenter -n -t "$pid" iptables -C "$@" 2>/dev/null; then
    return 1
  else
    nsenter -n -t "$pid" iptables -I "$@"
  fi
}

configure_tailscale_routing() {
  local tailscale_container_name="$1"
  local client_network="$2"

  if ! tailscale_container_meta="$(docker container inspect "$tailscale_container_name" 2>/dev/null | jq -e 'map(select(.State.Running))[0]')"; then
    return 50
  fi

  echo "INFO: [$tailscale_container_name] tailscale service container found" >&2
  tailscale_container_ip="$(echo "$tailscale_container_meta" | jq -r --arg net "$client_network" '.NetworkSettings.Networks[$net].IPAddress')"
  echo "DEBUG: [$tailscale_container_name] tailscale container ip: $tailscale_container_ip" >&2
  tailscale_pid="$(echo "$tailscale_container_meta" | jq -r '.State.Pid')"

  if ! tailscale_addrs="$(nsenter -n -t "$tailscale_pid" ip --json address)"; then
    echo "ERROR: [$tailscale_container_name] failed to get service container interfaces" >&2
    return 1
  fi
  if ! tailscale_tun_net_name="$(echo "$tailscale_addrs" | jq -re 'map(select(.ifname|startswith("tailscale")))[0].ifname')"; then
    echo "ERROR: [$tailscale_container_name] failed to find tailscale interface name" >&2
    return 1
  fi
  if ! tailscale_client_net_name="$(echo "$tailscale_addrs" | jq -re --arg ip "$tailscale_container_ip" 'map(select(.addr_info[0].local==$ip))[0].ifname')"; then
    echo "ERROR: [$tailscale_container_name] failed to find client network interface name with ip $tailscale_container_ip" >&2
    return 1
  fi

  ns_rule "$tailscale_pid" POSTROUTING -t nat -o "$tailscale_tun_net_name" -j MASQUERADE &&
    echo "INFO: [$tailscale_container_name] masquerade outgoing tunnel traffic" >&2
  ns_rule "$tailscale_pid" FORWARD -i "$tailscale_client_net_name" -o "$tailscale_tun_net_name" -j ACCEPT &&
    echo "INFO: [$tailscale_container_name] forward everything from client network to tunnel" >&2
  ns_rule "$tailscale_pid" FORWARD -i "$tailscale_tun_net_name" -m state --state ESTABLISHED,RELATED -j ACCEPT &&
    echo "INFO: [$tailscale_container_name] forward established,related from tunnel" >&2
  nsenter -n -t "$tailscale_pid" sysctl -w net.ipv4.ip_forward=1 >/dev/null &&
    echo "INFO: [$tailscale_container_name] enable forwarding" >&2
}

configure_client_routing() {
  local client_container_name="$1"
  local tailscale_container_name="$2"

  if ! client_container_meta="$(docker container inspect "$client_container_name" 2>/dev/null | jq -e 'map(select(.State.Running))[0]')"; then
    return 50
  fi

  echo "INFO: [$client_container_name] client container found" >&2
  client_pid="$(echo "$client_container_meta" | jq -r '.State.Pid')"

  client_resolv_conf="$(docker container exec "$client_container_name" cat /etc/resolv.conf)"
  if ! dns="$(echo "$client_resolv_conf" | grep -m 1 'nameserver ' | awk '{print $2}')" || [ -z "$dns" ]; then
    echo "ERROR: [$client_container_name] failed to read client container dns server" >&2
    return 1
  fi
  echo "DEBUG: [$client_container_name] dns server: $dns" >&2
  if ! tailscale_container_ip="$(nsenter -n -t "$client_pid" dig +short "$tailscale_container_name" "@$dns")" || [ -z "$tailscale_container_ip" ]; then
    echo "ERROR: [$client_container_name] failed to resolve tailscale container ip" >&2
    return 1
  fi
  echo "DEBUG: [$client_container_name] tailscale container ip: $tailscale_container_ip" >&2
  if ! client_gateway="$(nsenter -n -t "$client_pid" ip --json route | jq -re --arg route "$TAILSCALE_ROUTE" --arg ip "$tailscale_container_ip" 'map(select(.dst == $route and .gateway == $ip).gateway)[0]')"; then
    nsenter -n -t "$client_pid" ip route del "$TAILSCALE_ROUTE" 2>/dev/null &&
      echo "INFO: [$client_container_name] delete $TAILSCALE_ROUTE route" >&2
    nsenter -n -t "$client_pid" ip route add "$TAILSCALE_ROUTE" via "$tailscale_container_ip" &&
      echo "INFO: [$client_container_name] add route to $TAILSCALE_ROUTE via tailscale container ip $tailscale_container_ip" >&2

    comment="# tailscale dns"
    client_new_resolv_conf="$(
      echo "$client_resolv_conf" | sed "/$comment/,/nameserver .*/d"
      echo "$comment"
      echo "nameserver $TAILSCALE_DNS"
    )"
    echo "$client_new_resolv_conf" | docker container exec -i "$client_container_name" tee /etc/resolv.conf >/dev/null &&
      echo "INFO: [$client_container_name] add tailscale dns $TAILSCALE_DNS as nameserver" >&2
  fi
}

configure_routing() {
  local client_network="$1"
  local tailscale_container_name="$2"

  client_network_meta="$(docker network inspect "$client_network" | jq '.[0]')"

  if echo "$client_network_meta" | jq -e '.Internal|not' >/dev/null; then
    echo "WARN: client network is not set to internal and could leak traffic to the internet" >&2
  fi

  #if echo "$client_network_meta" | jq -e '.Options.icc != "true"' >/dev/null; then
  #  echo "ERROR: client network does not have icc enabled" >&2
  #  return 1
  #fi

  configure_tailscale_routing "$tailscale_container_name" "$client_network"
  case $? in
    0) :;;
    50)
      echo "INFO: [$tailscale_container_name] tailscale service container is running on another node" >&2
      ;;
    *)
      echo "ERROR: [$tailscale_container_name] failed to configure tailscale service container" >&2
      return 1
      ;;
  esac

  net_containers="$(echo "$client_network_meta" | jq '(.Containers // [])|to_entries|map(select(.key|startswith("lb-")|not)|.value.Name)')"

  while IFS= read -r client_container_name; do
    configure_client_routing "$client_container_name" "$tailscale_container_name"
    case $? in
      0) :;;
      50)
        echo "INFO: [$client_container_name] client container is running on another node" >&2
        ;;
      *)
        echo "ERROR: [$client_container_name] failed to configure client container" >&2
        return 1
        ;;
    esac
  done < <(echo "$net_containers" | jq -r --arg tailscale "$tailscale_container_name" 'map(select(. != $tailscale))[]')

  echo "INFO: finished" >&2
}

cleanup() {
  echo exiting >&2
  exit 0
}

trap cleanup SIGINT SIGTERM

if [ -z "$TAILSCALE_SERVICE_NAME" ]; then
  echo "ERROR: TAILSCALE_SERVICE_NAME is not set" >&2
  exit 1
fi
if [ -z "$CLIENT_NETWORK" ]; then
  echo "ERROR: CLIENT_NETWORK is not set" >&2
  exit 1
fi

while true; do
  if tailscale_container_name=$(get_container_name_for_service "$TAILSCALE_SERVICE_NAME"); then
    configure_routing "$CLIENT_NETWORK" "$tailscale_container_name"
  fi
  sleep "$INTERVAL" &
  wait
done
