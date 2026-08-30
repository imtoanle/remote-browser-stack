#!/usr/bin/env bash
set -euo pipefail

CLIENT_NAME=""
CLIENT_ADDRESS=""
OUTPUT=""
DNS=""

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/add-wireguard-peer.sh \
  --client-name <name> \
  --client-address <cidr> \
  [--output /root/client.conf] \
  [--dns 1.1.1.1]

The WireGuard server must already be provisioned with
scripts/install-wireguard-server.sh.
EOF
}

validate_ipv4_cidr() {
  local cidr="$1"
  local ip prefix octet extra
  local -a octets

  [[ "$cidr" == */* ]] || return 1
  ip="${cidr%/*}"
  prefix="${cidr##*/}"
  [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
  if (( prefix > 32 )); then
    return 1
  fi

  IFS='.' read -r -a octets <<< "$ip"
  [[ "${#octets[@]}" -eq 4 ]] || return 1
  extra="${ip//[0-9.]/}"
  [[ -z "$extra" ]] || return 1

  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    if (( 10#$octet > 255 )); then
      return 1
    fi
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client-name) CLIENT_NAME="${2:-}"; shift 2 ;;
    --client-address) CLIENT_ADDRESS="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --dns) DNS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || { printf 'Run as root.\n' >&2; exit 1; }
[[ -n "$CLIENT_NAME" ]] || { printf -- '--client-name is required\n' >&2; exit 2; }
[[ -n "$CLIENT_ADDRESS" ]] || { printf -- '--client-address is required\n' >&2; exit 2; }
[[ "$CLIENT_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || { printf 'Invalid client name.\n' >&2; exit 2; }
validate_ipv4_cidr "$CLIENT_ADDRESS" || { printf 'Invalid IPv4 --client-address: %s\n' "$CLIENT_ADDRESS" >&2; exit 2; }

WG_DIR="/etc/wireguard"
KEY_DIR="$WG_DIR/rbs-keys"
SERVER_META="$WG_DIR/rbs-server.env"
SERVER_PRIVATE="$KEY_DIR/server.key"
SERVER_PUBLIC="$KEY_DIR/server.pub"
CLIENT_PRIVATE="$KEY_DIR/client-${CLIENT_NAME}.key"
CLIENT_PUBLIC="$KEY_DIR/client-${CLIENT_NAME}.pub"
CLIENT_ADDR_FILE="$KEY_DIR/client-${CLIENT_NAME}.address"

[[ -s "$SERVER_META" ]] || {
  printf 'Missing %s. Provision the server first with install-wireguard-server.sh.\n' "$SERVER_META" >&2
  exit 1
}
[[ -s "$SERVER_PRIVATE" ]] || { printf 'Missing WireGuard server private key: %s\n' "$SERVER_PRIVATE" >&2; exit 1; }

# shellcheck disable=SC1090
source "$SERVER_META"
: "${RBS_INTERFACE:?missing RBS_INTERFACE in $SERVER_META}"
: "${RBS_LISTEN_PORT:?missing RBS_LISTEN_PORT in $SERVER_META}"
: "${RBS_SERVER_ADDRESS:?missing RBS_SERVER_ADDRESS in $SERVER_META}"
: "${RBS_ENDPOINT:?missing RBS_ENDPOINT in $SERVER_META}"

WG_CONF="$WG_DIR/${RBS_INTERFACE}.conf"
OUTPUT="${OUTPUT:-/root/${CLIENT_NAME}.conf}"
[[ -s "$WG_CONF" ]] || { printf 'Missing WireGuard interface config: %s\n' "$WG_CONF" >&2; exit 1; }

for command in wg wg-quick find sort; do
  command -v "$command" >/dev/null 2>&1 || { printf 'Required command not found: %s\n' "$command" >&2; exit 1; }
done

install -d -m 0700 "$KEY_DIR"

for addr_file in "$KEY_DIR"/client-*.address; do
  [[ -e "$addr_file" ]] || break
  [[ "$addr_file" == "$CLIENT_ADDR_FILE" ]] && continue
  if [[ "$(cat "$addr_file")" == "$CLIENT_ADDRESS" ]]; then
    printf 'Client address %s is already assigned in %s\n' "$CLIENT_ADDRESS" "$addr_file" >&2
    exit 2
  fi
done

if [[ ! -s "$SERVER_PUBLIC" || "$SERVER_PRIVATE" -nt "$SERVER_PUBLIC" ]]; then
  wg pubkey < "$SERVER_PRIVATE" > "$SERVER_PUBLIC"
fi
if [[ ! -s "$CLIENT_PRIVATE" ]]; then
  umask 077
  wg genkey > "$CLIENT_PRIVATE"
fi
if [[ ! -s "$CLIENT_PUBLIC" || "$CLIENT_PRIVATE" -nt "$CLIENT_PUBLIC" ]]; then
  wg pubkey < "$CLIENT_PRIVATE" > "$CLIENT_PUBLIC"
fi

printf '%s\n' "$CLIENT_ADDRESS" > "$CLIENT_ADDR_FILE"
chmod 0600 "$CLIENT_PRIVATE" "$CLIENT_ADDR_FILE"
chmod 0644 "$CLIENT_PUBLIC" "$SERVER_PUBLIC"

server_private_key="$(cat "$SERVER_PRIVATE")"
server_public_key="$(cat "$SERVER_PUBLIC")"
client_private_key="$(cat "$CLIENT_PRIVATE")"

{
  cat <<EOF
[Interface]
Address = $RBS_SERVER_ADDRESS
ListenPort = $RBS_LISTEN_PORT
PrivateKey = $server_private_key
SaveConfig = false
EOF

  while IFS= read -r pub_file; do
    name="$(basename "$pub_file")"
    name="${name#client-}"
    name="${name%.pub}"
    addr_file="$KEY_DIR/client-${name}.address"
    [[ -s "$addr_file" ]] || continue
    printf '\n# rbs-client:%s\n' "$name"
    printf '[Peer]\nPublicKey = %s\nAllowedIPs = %s\n' "$(cat "$pub_file")" "$(cat "$addr_file")"
  done < <(find "$KEY_DIR" -maxdepth 1 -type f -name 'client-*.pub' | sort)
} > "${WG_CONF}.tmp"
chmod 0600 "${WG_CONF}.tmp"
mv "${WG_CONF}.tmp" "$WG_CONF"

if wg show "$RBS_INTERFACE" >/dev/null 2>&1; then
  wg syncconf "$RBS_INTERFACE" <(wg-quick strip "$WG_CONF")
else
  systemctl restart "wg-quick@${RBS_INTERFACE}"
fi

install -d -m 0700 "$(dirname "$OUTPUT")"
{
  printf '[Interface]\nPrivateKey = %s\nAddress = %s\n' "$client_private_key" "$CLIENT_ADDRESS"
  if [[ -n "$DNS" ]]; then
    printf 'DNS = %s\n' "$DNS"
  fi
  printf '\n[Peer]\nPublicKey = %s\nEndpoint = %s:%s\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n' \
    "$server_public_key" "$RBS_ENDPOINT" "$RBS_LISTEN_PORT"
} > "$OUTPUT"
chmod 0600 "$OUTPUT"

cat <<EOF
WireGuard peer ready.
Interface: $RBS_INTERFACE
Client: $CLIENT_NAME ($CLIENT_ADDRESS)
Client config: $OUTPUT

Copy the client config securely to the matching remote-browser-stack account's wireguard.conf.
EOF
