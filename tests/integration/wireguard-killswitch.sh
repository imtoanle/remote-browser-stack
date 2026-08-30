#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

command -v docker >/dev/null 2>&1 || {
  printf 'docker is required for the WireGuard kill-switch integration test\n' >&2
  exit 1
}
[[ -c /dev/net/tun ]] || { printf '/dev/net/tun is required\n' >&2; exit 1; }

suffix="${GITHUB_RUN_ID:-local}-$$"
network="rbs-wg-test-${suffix}"
server="rbs-wg-server-${suffix}"
vpn="rbs-wg-client-${suffix}"
probe="rbs-wg-probe-${suffix}"
server_image="rbs-wireguard-test-server:ci"
tmp="$(mktemp -d)"

cleanup() {
  docker rm -f "$probe" "$vpn" "$server" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

docker build -t "$server_image" -f tests/integration/Dockerfile.wireguard-server . >/dev/null

umask 077
docker run --rm "$server_image" wg genkey > "$tmp/server.key"
docker run --rm -i "$server_image" wg pubkey < "$tmp/server.key" > "$tmp/server.pub"
docker run --rm "$server_image" wg genkey > "$tmp/client.key"
docker run --rm -i "$server_image" wg pubkey < "$tmp/client.key" > "$tmp/client.pub"

cat > "$tmp/server.conf" <<EOF
[Interface]
Address = 10.77.0.1/24
ListenPort = 51820
PrivateKey = $(cat "$tmp/server.key")

[Peer]
PublicKey = $(cat "$tmp/client.pub")
AllowedIPs = 10.77.0.2/32
EOF

docker network create "$network" >/dev/null

docker run -d \
  --name "$server" \
  --network "$network" \
  --cap-add NET_ADMIN \
  --device /dev/net/tun:/dev/net/tun \
  --sysctl net.ipv4.ip_forward=1 \
  -v "$tmp/server.conf:/config/wg0.conf:ro" \
  "$server_image" \
  sh -euxc '
    cp /config/wg0.conf /etc/wireguard/wg0.conf
    chmod 600 /etc/wireguard/wg0.conf
    wg-quick up wg0
    iptables -A FORWARD -i wg0 -o eth0 -j ACCEPT
    iptables -A FORWARD -i eth0 -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    exec sleep infinity
  ' >/dev/null

server_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$server")"
[[ -n "$server_ip" ]] || { printf 'Could not determine ephemeral WireGuard server IP\n' >&2; exit 1; }

cat > "$tmp/client.conf" <<EOF
[Interface]
PrivateKey = $(cat "$tmp/client.key")
Address = 10.77.0.2/32

[Peer]
PublicKey = $(cat "$tmp/server.pub")
Endpoint = ${server_ip}:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 5
EOF

docker run -d \
  --name "$vpn" \
  --network "$network" \
  --cap-add NET_ADMIN \
  --device /dev/net/tun:/dev/net/tun \
  -e VPN_SERVICE_PROVIDER=custom \
  -e VPN_TYPE=wireguard \
  -v "$tmp/client.conf:/gluetun/wireguard/wg0.conf:ro" \
  qmcgaw/gluetun:v3.41.1 >/dev/null

for _ in {1..30}; do
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$vpn")"
  [[ "$health" == "healthy" ]] && break
  if [[ "$(docker inspect -f '{{.State.Running}}' "$vpn")" != "true" ]]; then
    docker logs "$vpn"
    exit 1
  fi
  sleep 1
done

health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$vpn")"
[[ "$health" == "healthy" ]] || {
  docker logs "$vpn"
  printf 'Gluetun did not become healthy\n' >&2
  exit 1
}

docker run -d \
  --name "$probe" \
  --network "container:${vpn}" \
  --entrypoint sh \
  curlimages/curl:8.12.1 \
  -c 'sleep 3600' >/dev/null

printf 'Phase A: verify Internet works through WireGuard...\n'
if ! docker exec "$probe" curl -kfsS --max-time 10 https://1.1.1.1/cdn-cgi/trace > "$tmp/healthy-trace"; then
  docker logs "$vpn"
  printf 'Probe could not reach the Internet through the healthy WireGuard tunnel\n' >&2
  exit 1
fi
grep -q '^ip=' "$tmp/healthy-trace" || {
  cat "$tmp/healthy-trace" >&2
  printf 'Unexpected Cloudflare trace response\n' >&2
  exit 1
}

if ! docker exec "$server" wg show wg0 latest-handshakes | awk '$2 > 0 {found=1} END {exit !found}'; then
  docker exec "$server" wg show
  printf 'No WireGuard handshake was observed on the test server\n' >&2
  exit 1
fi

printf 'Phase B: stop the WireGuard endpoint and verify Gluetun fails closed...\n'
docker stop "$server" >/dev/null
sleep 3

for _ in 1 2 3; do
  if docker exec "$probe" curl -kfsS --max-time 5 https://1.1.1.1/cdn-cgi/trace >/dev/null 2>&1; then
    printf 'FAIL: probe reached the Internet after WireGuard server shutdown; direct fallback leaked through Gluetun namespace\n' >&2
    exit 1
  fi
done

vpn_id="$(docker inspect -f '{{.Id}}' "$vpn")"
probe_mode="$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$probe")"
[[ "$probe_mode" == "container:${vpn_id}" ]] || {
  printf 'Probe unexpectedly has an independent network mode: %s\n' "$probe_mode" >&2
  exit 1
}

printf 'WireGuard kill-switch integration: PASS\n'
