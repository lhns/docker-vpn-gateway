#!/bin/bash

set -o pipefail

ns_rule() {
  local pid="$1"
  shift
  if nsenter -n -t "$pid" iptables -C "$@" 2>/dev/null; then
    return 1
  else
    nsenter -n -t "$pid" iptables -I "$@"
  fi
}

configure_tun_routing() {
  local tun_container_name="$1"
  local client_network="$2"

  if ! tun_container_meta="$(docker container inspect "$tun_container_name" 2>/dev/null | jq -e 'map(select(.State.Running))[0]')"; then
    return 50
  fi

  echo "INFO: [$tun_container_name] tun container found" >&2
  tun_container_ip="$(echo "$tun_container_meta" | jq -r --arg net "$client_network" '.NetworkSettings.Networks[$net].IPAddress')"
  echo "DEBUG: [$tun_container_name] tun container ip: $tun_container_ip" >&2
  tun_pid="$(echo "$tun_container_meta" | jq -r '.State.Pid')"

  if ! tun_addrs="$(nsenter -n -t "$tun_pid" ip --json address)"; then
    echo "ERROR: [$tun_container_name] failed to get tun container interfaces" >&2
    return 1
  fi
  if ! tun_tun_net_name="$(echo "$tun_addrs" | jq -re 'map(select(.ifname|startswith("tun")))[0].ifname')"; then
    echo "ERROR: [$tun_container_name] failed to find tun interface name" >&2
    return 1
  fi
  if ! tun_client_net_name="$(echo "$tun_addrs" | jq -re --arg ip "$tun_container_ip" 'map(select(.addr_info[0].local==$ip))[0].ifname')"; then
    echo "ERROR: [$tun_container_name] failed to find client network interface name with ip $tun_container_ip" >&2
    return 1
  fi

  ns_rule "$tun_pid" POSTROUTING -t nat -o "$tun_tun_net_name" -j MASQUERADE &&
    echo "INFO: [$tun_container_name] masquerade outgoing tunnel traffic" >&2
  ns_rule "$tun_pid" FORWARD -i "$tun_client_net_name" -o "$tun_tun_net_name" -j ACCEPT &&
    echo "INFO: [$tun_container_name] forward everything from client network to tunnel" >&2
  ns_rule "$tun_pid" FORWARD -i "$tun_tun_net_name" -m state --state ESTABLISHED,RELATED -j ACCEPT &&
    echo "INFO: [$tun_container_name] forward established,related from tunnel" >&2
  nsenter -n -t "$tun_pid" sysctl -w net.ipv4.ip_forward=1 >/dev/null &&
    echo "INFO: [$tun_container_name] enable forwarding" >&2
}

configure_client_routing() {
  local client_container_name="$1"
  local tun_container_name="$2"

  if ! client_container_meta="$(docker container inspect "$client_container_name" 2>/dev/null | jq -e 'map(select(.State.Running))[0]')"; then
    return 50
  fi

  echo "INFO: [$client_container_name] client container found" >&2
  client_pid="$(echo "$client_container_meta" | jq -r '.State.Pid')"

  client_resolv_conf="$(docker container exec "$client_container_name" cat /etc/resolv.conf)"
  if ! dns="$(echo "$client_resolv_conf" | grep -m 1 'nameserver 127' | awk '{print $2}')" || [ -z "$dns" ]; then
    echo "ERROR: [$client_container_name] failed to read client container dns server" >&2
    return 1
  fi
  echo "DEBUG: [$client_container_name] dns server: $dns" >&2
  if ! tun_container_ip="$(nsenter -n -t "$client_pid" dig +short "$tun_container_name" "@$dns")" || [ -z "$tun_container_ip" ]; then
    echo "ERROR: [$client_container_name] failed to resolve tun container ip" >&2
    return 1
  fi
  echo "DEBUG: [$client_container_name] tun container ip: $tun_container_ip" >&2
  if ! client_gateway="$(nsenter -n -t "$client_pid" ip --json route | jq -re --arg ip "$tun_container_ip" 'map(select(.dst == "default" and .gateway == $ip).gateway)[0]')"; then
    nsenter -n -t "$client_pid" ip route del default 2>/dev/null &&
      echo "INFO: [$client_container_name] delete default route" >&2
    nsenter -n -t "$client_pid" ip route add default via "$tun_container_ip" &&
      echo "INFO: [$client_container_name] add default route via tun container ip $tun_container_ip" >&2

    comment="# tun container ip"
    client_new_resolv_conf="$(
      echo "$client_resolv_conf" | sed "/$comment/,/nameserver .*/d"
      echo "$comment"
      echo "nameserver $tun_container_ip"
    )"
    echo "$client_new_resolv_conf" | docker container exec -i "$client_container_name" tee /etc/resolv.conf >/dev/null &&
      echo "INFO: [$client_container_name] add tun container ip $tun_container_ip as nameserver" >&2
  fi
}

configure_routing() {
  local client_network="$1"
  local tun_container_name="$2"

  client_network_meta="$(docker network inspect "$client_network" | jq '.[0]')"

  if echo "$client_network_meta" | jq -e '.Internal|not' >/dev/null; then
    echo "WARN: client network is not set to internal and could leak traffic to the internet" >&2
  fi

  #if echo "$client_network_meta" | jq -e '.Options.icc != "true"' >/dev/null; then
  #  echo "ERROR: client network does not have icc enabled" >&2
  #  return 1
  #fi

  configure_tun_routing "$tun_container_name" "$client_network"
  case $? in
    0) :;;
    50)
      echo "INFO: [$tun_container_name] tun container is running on another node" >&2
      ;;
    *)
      echo "ERROR: [$tun_container_name] failed to configure tun container" >&2
      return 1
      ;;
  esac

  net_containers="$(echo "$client_network_meta" | jq '(.Containers // [])|to_entries|map(select(.key|startswith("lb-")|not)|.value.Name)')"

  while IFS= read -r client_container_name; do
    configure_client_routing "$client_container_name" "$tun_container_name"
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
  done < <(echo "$net_containers" | jq -r --arg tun "$tun_container_name" 'map(select(. != $tun))[]')

  echo "INFO: finished" >&2
}

cleanup() {
  echo exiting >&2
  exit 0
}

trap cleanup SIGINT SIGTERM

while true; do
  configure_routing "$CLIENT_NETWORK" "$TUN_CONTAINER_NAME"
  sleep "$INTERVAL" &
  wait
done
