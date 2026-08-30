#!/usr/bin/env bash
set -euo pipefail

WG_IF="wg0"
LISTEN_PORT="51820"
SERVER_ADDRESS="10.77.0.1/24"
ENDPOINT=""
CLIENT_NAME=""
CLIENT_ADDRESS=""
OUTPUT=""
WAN_IF=""
DNS=""

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/install-wireguard-server.sh \
  --endpoint <public-host-or-ip> \
  --client-name <name> \
  --client-address <cidr> \
  [--interface wg0] \
  [--listen-port 51820] \
  [--server-address 10.77.0.1/24] \
  [--output /root/client.conf] \
  [--wan-interface eth0] \
  [--dns 1.1.1.1]
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
    --endpoint) ENDPOINT="${2:-}"; shift 2 ;;
    --interface) WG_IF="${2:-}"; shift 2 ;;
    --listen-port) LISTEN_PORT="${2:-}"; shift 2 ;;
    --server-address) SERVER_ADDRESS="${2:-}"; shift 2 ;;
    --client-name) CLIENT_NAME="${2:-}"; shift 2 ;;
    --client-address) CLIENT_ADDRESS="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --wan-interface) WAN_IF="${2:-}"; shift 2 ;;
    --dns) DNS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || { printf 'Run as root.\n' >&2; exit 1; }
[[ -n "$ENDPOINT" ]] || { printf -- '--endpoint is required\n' >&2; exit 2; }
[[ -n "$CLIENT_NAME" ]] || { printf -- '--client-name is required\n' >&2; exit 2; }
[[ -n "$CLIENT_ADDRESS" ]] || { printf -- '--client-address is required\n' >&2; exit 2; }
[[ "$WG_IF" =~ ^[A-Za-z0-9_.-]+$ && ${#WG_IF} -le 15 ]] || { printf 'Invalid WireGuard interface name.\n' >&2; exit 2; }
[[ "$CLIENT_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || { printf 'Invalid client name.\n' >&2; exit 2; }
if [[ ! "$LISTEN_PORT" =~ ^[0-9]+$ ]] || (( LISTEN_PORT < 1 || LISTEN_PORT > 65535 )); then
  printf 'Invalid listen port.\n' >&2
  exit 2
fi
validate_ipv4_cidr "$SERVER_ADDRESS" || { printf 'Invalid IPv4 --server-address: %s\n' "$SERVER_ADDRESS" >&2; exit 2; }
validate_ipv4_cidr "$CLIENT_ADDRESS" || { printf 'Invalid IPv4 --client-address: %s\n' "$CLIENT_ADDRESS" >&2; exit 2; }

# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in
  debian|ubuntu) ;;
  *) printf 'Supported hosts are Debian and Ubuntu. Detected: %s\n' "${ID:-unknown}" >&2; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends wireguard-tools nftables iproute2 ca-certificates

if [[ -z "$WAN_IF" ]]; then
  WAN_IF="$(ip -4 route show default | awk 'NR==1 {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
fi
[[ -n "$WAN_IF" ]] || { printf 'Cannot infer WAN interface; pass --wan-interface.\n' >&2; exit 1; }
[[ "$WAN_IF" =~ ^[A-Za-z0-9_.:-]+$ ]] || { printf 'Invalid WAN interface name.\n' >&2; exit 2; }

WG_DIR="/etc/wireguard"
KEY_DIR="$WG_DIR/rbs-keys"
SERVER_PRIVATE="$KEY_DIR/server.key"
SERVER_PUBLIC="$KEY_DIR/server.pub"
CLIENT_PRIVATE="$KEY_DIR/client-${CLIENT_NAME}.key"
CLIENT_PUBLIC="$KEY_DIR/client-${CLIENT_NAME}.pub"
CLIENT_ADDR_FILE="$KEY_DIR/client-${CLIENT_NAME}.address"
WG_CONF="$WG_DIR/${WG_IF}.conf"
SERVER_META="$WG_DIR/rbs-server.env"
NFT_DIR="/etc/nftables.d"
NFT_FILE="$NFT_DIR/rbs-wireguard.nft"
SYSCTL_FILE="/etc/sysctl.d/99-rbs-wireguard.conf"
OUTPUT="${OUTPUT:-/root/${CLIENT_NAME}.conf}"

install -d -m 0700 "$WG_DIR" "$KEY_DIR"
install -d -m 0755 "$NFT_DIR"

if [[ ! -s "$SERVER_PRIVATE" ]]; then
  umask 077
  wg genkey > "$SERVER_PRIVATE"
fi
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
chmod 0600 "$SERVER_PRIVATE" "$CLIENT_PRIVATE" "$CLIENT_ADDR_FILE"
chmod 0644 "$SERVER_PUBLIC" "$CLIENT_PUBLIC"

{
  printf 'RBS_INTERFACE=%q\n' "$WG_IF"
  printf 'RBS_LISTEN_PORT=%q\n' "$LISTEN_PORT"
  printf 'RBS_SERVER_ADDRESS=%q\n' "$SERVER_ADDRESS"
  printf 'RBS_ENDPOINT=%q\n' "$ENDPOINT"
} > "$SERVER_META"
chmod 0600 "$SERVER_META"

server_private_key="$(cat "$SERVER_PRIVATE")"
server_public_key="$(cat "$SERVER_PUBLIC")"
client_private_key="$(cat "$CLIENT_PRIVATE")"

{
  cat <<EOF
[Interface]
Address = $SERVER_ADDRESS
ListenPort = $LISTEN_PORT
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

cat > "$SYSCTL_FILE" <<'EOF'
net.ipv4.ip_forward=1
EOF
sysctl -w net.ipv4.ip_forward=1 >/dev/null

cat > "$NFT_FILE" <<EOF
# Managed by remote-browser-stack. Do not edit manually.
table inet rbs_wg {
  chain forward {
    type filter hook forward priority filter; policy accept;
    iifname "$WG_IF" oifname "$WAN_IF" accept
    iifname "$WAN_IF" oifname "$WG_IF" ct state established,related accept
  }

  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    iifname "$WG_IF" oifname "$WAN_IF" masquerade
  }
}
EOF

if [[ ! -f /etc/nftables.conf ]]; then
  cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
EOF
fi
include_line='include "/etc/nftables.d/rbs-wireguard.nft"'
grep -Fqx "$include_line" /etc/nftables.conf || printf '\n%s\n' "$include_line" >> /etc/nftables.conf

systemctl enable nftables >/dev/null
systemctl restart nftables
systemctl enable "wg-quick@${WG_IF}" >/dev/null
systemctl restart "wg-quick@${WG_IF}"

install -d -m 0700 "$(dirname "$OUTPUT")"
{
  printf '[Interface]\nPrivateKey = %s\nAddress = %s\n' "$client_private_key" "$CLIENT_ADDRESS"
  if [[ -n "$DNS" ]]; then
    printf 'DNS = %s\n' "$DNS"
  fi
  printf '\n[Peer]\nPublicKey = %s\nEndpoint = %s:%s\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n' \
    "$server_public_key" "$ENDPOINT" "$LISTEN_PORT"
} > "$OUTPUT"
chmod 0600 "$OUTPUT"

cat <<EOF
WireGuard server ready.
Interface: $WG_IF
Listen port: $LISTEN_PORT
WAN interface: $WAN_IF
Client: $CLIENT_NAME ($CLIENT_ADDRESS)
Client config: $OUTPUT

Copy the client config securely to the remote-browser-stack account's wireguard.conf.
Add later peers with scripts/add-wireguard-peer.sh on this server.
EOF
