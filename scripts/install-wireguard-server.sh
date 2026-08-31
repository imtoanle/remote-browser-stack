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
SSH_TARGET=""

usage() {
  cat <<'EOF'
Usage: ./scripts/install-wireguard-server.sh <root@host> \
  --client-name <name> \
  [--client-address <cidr>] \
  [--endpoint <public-host-or-ip>] \
  [--interface wg0] \
  [--listen-port 51820] \
  [--server-address 10.77.0.1/24] \
  [--output ./client.conf] \
  [--wan-interface eth0] \
  [--dns 1.1.1.1]

Run this on the local workstation. The script streams itself over SSH, so the
remote server does not need a repository checkout. The SSH host is used as the
public endpoint when --endpoint is omitted. The next free client /32 is chosen
when --client-address is omitted.
EOF
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

validate_ipv4_cidr() {
  local cidr="$1" ip prefix octet extra
  local -a octets
  [[ "$cidr" == */* ]] || return 1
  ip="${cidr%/*}"
  prefix="${cidr##*/}"
  [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
  (( prefix <= 32 )) || return 1
  IFS='.' read -r -a octets <<< "$ip"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  extra="${ip//[0-9.]/}"
  [[ -z "$extra" ]] || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done
}

ipv4_to_int() {
  local a b c d
  IFS='.' read -r a b c d <<< "$1"
  printf '%u' "$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))"
}

int_to_ipv4() {
  local value="$1"
  printf '%d.%d.%d.%d' \
    "$(( (value >> 24) & 255 ))" "$(( (value >> 16) & 255 ))" \
    "$(( (value >> 8) & 255 ))" "$(( value & 255 ))"
}

address_is_used_by_other_client() {
  local client_name="$1" candidate="$2" key_dir="$3" addr_file stored
  shopt -s nullglob
  for addr_file in "$key_dir"/client-*.address; do
    [[ "$addr_file" == "$key_dir/client-${client_name}.address" ]] && continue
    stored="$(cat "$addr_file")"
    if [[ "${stored%/*}" == "${candidate%/*}" ]]; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

select_client_address() {
  local client_name="$1" requested="$2" server_address="$3" key_dir="$4"
  local existing_file="$key_dir/client-${client_name}.address"
  local server_ip server_prefix server_int mask network broadcast
  local requested_ip requested_prefix requested_int candidate candidate_cidr

  validate_ipv4_cidr "$server_address" || {
    printf 'Invalid IPv4 server address: %s\n' "$server_address" >&2
    return 2
  }
  if [[ -z "$requested" && -s "$existing_file" ]]; then
    cat "$existing_file"
    return 0
  fi

  server_ip="${server_address%/*}"
  server_prefix="${server_address##*/}"
  server_int="$(ipv4_to_int "$server_ip")"
  if (( server_prefix == 0 )); then
    mask=0
  else
    mask=$(( (0xFFFFFFFF << (32 - server_prefix)) & 0xFFFFFFFF ))
  fi
  network=$(( server_int & mask ))
  broadcast=$(( network | (0xFFFFFFFF ^ mask) ))

  if [[ -n "$requested" ]]; then
    validate_ipv4_cidr "$requested" || { printf 'Invalid IPv4 client address: %s\n' "$requested" >&2; return 2; }
    requested_ip="${requested%/*}"
    requested_prefix="${requested##*/}"
    [[ "$requested_prefix" == "32" ]] || { printf 'Client address must use /32: %s\n' "$requested" >&2; return 2; }
    requested_int="$(ipv4_to_int "$requested_ip")"
    if (( requested_int <= network || requested_int >= broadcast || requested_int == server_int )); then
      printf 'Client address %s is not usable in %s\n' "$requested" "$server_address" >&2
      return 2
    fi
    address_is_used_by_other_client "$client_name" "$requested" "$key_dir" && {
      printf 'Client address %s is already assigned to another client\n' "$requested" >&2
      return 2
    }
    printf '%s' "$requested"
    return 0
  fi

  for ((candidate = network + 1; candidate < broadcast; candidate++)); do
    (( candidate == server_int )) && continue
    candidate_cidr="$(int_to_ipv4 "$candidate")/32"
    if ! address_is_used_by_other_client "$client_name" "$candidate_cidr" "$key_dir"; then
      printf '%s' "$candidate_cidr"
      return 0
    fi
  done
  printf 'No free client address remains in %s\n' "$server_address" >&2
  return 1
}

parse_remote_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --endpoint) ENDPOINT="${2:-}"; shift 2 ;;
      --interface) WG_IF="${2:-}"; shift 2 ;;
      --listen-port) LISTEN_PORT="${2:-}"; shift 2 ;;
      --server-address) SERVER_ADDRESS="${2:-}"; shift 2 ;;
      --client-name) CLIENT_NAME="${2:-}"; shift 2 ;;
      --client-address) CLIENT_ADDRESS="${2:-}"; shift 2 ;;
      --wan-interface) WAN_IF="${2:-}"; shift 2 ;;
      --dns) DNS="${2:-}"; shift 2 ;;
      *) printf 'Unknown remote argument: %s\n' "$1" >&2; exit 2 ;;
    esac
  done
}

remote_install() {
  parse_remote_args "$@"
  [[ ${EUID} -eq 0 ]] || fail 'Remote installer must run as root.'
  [[ -n "$ENDPOINT" ]] || fail '--endpoint is required in remote mode'
  [[ -n "$CLIENT_NAME" ]] || fail '--client-name is required'
  [[ "$WG_IF" =~ ^[A-Za-z0-9_.-]+$ && ${#WG_IF} -le 15 ]] || fail 'Invalid WireGuard interface name.'
  [[ "$CLIENT_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || fail 'Invalid client name.'
  [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] && (( LISTEN_PORT >= 1 && LISTEN_PORT <= 65535 )) || fail 'Invalid listen port.'
  validate_ipv4_cidr "$SERVER_ADDRESS" || fail "Invalid IPv4 --server-address: $SERVER_ADDRESS"
  [[ -z "$CLIENT_ADDRESS" ]] || validate_ipv4_cidr "$CLIENT_ADDRESS" || fail "Invalid IPv4 --client-address: $CLIENT_ADDRESS"

  # Keep SSH stdout machine-readable: provisioning logs go to stderr and the
  # generated client config is emitted through fd 3 only at the end.
  exec 3>&1
  exec 1>&2

  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in debian|ubuntu) ;; *) fail "Supported remote hosts are Debian/Ubuntu; found ${ID:-unknown}" ;; esac

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends wireguard-tools nftables iproute2 ca-certificates util-linux

  if [[ -z "$WAN_IF" ]]; then
    WAN_IF="$(ip -4 route show default | awk 'NR==1 {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
  fi
  [[ -n "$WAN_IF" ]] || fail 'Cannot infer WAN interface; pass --wan-interface.'
  [[ "$WAN_IF" =~ ^[A-Za-z0-9_.:-]+$ ]] || fail 'Invalid WAN interface name.'

  WG_DIR="/etc/wireguard"
  KEY_DIR="$WG_DIR/rbs-keys"
  SERVER_PRIVATE="$KEY_DIR/server.key"
  SERVER_PUBLIC="$KEY_DIR/server.pub"
  CLIENT_PRIVATE="$KEY_DIR/client-${CLIENT_NAME}.key"
  CLIENT_PUBLIC="$KEY_DIR/client-${CLIENT_NAME}.pub"
  CLIENT_ADDR_FILE="$KEY_DIR/client-${CLIENT_NAME}.address"
  WG_CONF="$WG_DIR/${WG_IF}.conf"
  SERVER_META="$WG_DIR/rbs-server.env"
  LOCK_FILE="$WG_DIR/rbs-peer-allocation.lock"
  NFT_DIR="/etc/nftables.d"
  NFT_FILE="$NFT_DIR/rbs-wireguard.nft"
  SYSCTL_FILE="/etc/sysctl.d/99-rbs-wireguard.conf"

  install -d -m 0700 "$WG_DIR" "$KEY_DIR"
  install -d -m 0755 "$NFT_DIR"
  touch "$LOCK_FILE"
  chmod 0600 "$LOCK_FILE"

  # Serialize allocation, state persistence and config rebuild. Without this,
  # simultaneous local invocations could both observe the same free address.
  exec 9>"$LOCK_FILE"
  flock -x 9

  CLIENT_ADDRESS="$(select_client_address "$CLIENT_NAME" "$CLIENT_ADDRESS" "$SERVER_ADDRESS" "$KEY_DIR")"

  if [[ ! -s "$SERVER_PRIVATE" ]]; then umask 077; wg genkey > "$SERVER_PRIVATE"; fi
  if [[ ! -s "$SERVER_PUBLIC" || "$SERVER_PRIVATE" -nt "$SERVER_PUBLIC" ]]; then wg pubkey < "$SERVER_PRIVATE" > "$SERVER_PUBLIC"; fi
  if [[ ! -s "$CLIENT_PRIVATE" ]]; then umask 077; wg genkey > "$CLIENT_PRIVATE"; fi
  if [[ ! -s "$CLIENT_PUBLIC" || "$CLIENT_PRIVATE" -nt "$CLIENT_PUBLIC" ]]; then wg pubkey < "$CLIENT_PRIVATE" > "$CLIENT_PUBLIC"; fi

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
    printf '[Interface]\nAddress = %s\nListenPort = %s\nPrivateKey = %s\nSaveConfig = false\n' \
      "$SERVER_ADDRESS" "$LISTEN_PORT" "$server_private_key"
    while IFS= read -r pub_file; do
      name="$(basename "$pub_file")"; name="${name#client-}"; name="${name%.pub}"
      addr_file="$KEY_DIR/client-${name}.address"
      [[ -s "$addr_file" ]] || continue
      printf '\n# rbs-client:%s\n[Peer]\nPublicKey = %s\nAllowedIPs = %s\n' \
        "$name" "$(cat "$pub_file")" "$(cat "$addr_file")"
    done < <(find "$KEY_DIR" -maxdepth 1 -type f -name 'client-*.pub' | sort)
  } > "${WG_CONF}.tmp"
  chmod 0600 "${WG_CONF}.tmp"
  mv "${WG_CONF}.tmp" "$WG_CONF"

  printf 'net.ipv4.ip_forward=1\n' > "$SYSCTL_FILE"
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
  if [[ ! -f /etc/nftables.conf ]]; then printf '#!/usr/sbin/nft -f\n' > /etc/nftables.conf; fi
  include_line='include "/etc/nftables.d/rbs-wireguard.nft"'
  grep -Fqx "$include_line" /etc/nftables.conf || printf '\n%s\n' "$include_line" >> /etc/nftables.conf

  systemctl enable nftables >/dev/null
  systemctl restart nftables
  systemctl enable "wg-quick@${WG_IF}" >/dev/null
  systemctl restart "wg-quick@${WG_IF}"

  printf 'WireGuard server ready: %s, client %s (%s)\n' "$ENDPOINT" "$CLIENT_NAME" "$CLIENT_ADDRESS" >&2
  {
    printf '[Interface]\nPrivateKey = %s\nAddress = %s\n' "$client_private_key" "$CLIENT_ADDRESS"
    [[ -z "$DNS" ]] || printf 'DNS = %s\n' "$DNS"
    printf '\n[Peer]\nPublicKey = %s\nEndpoint = %s:%s\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n' \
      "$server_public_key" "$ENDPOINT" "$LISTEN_PORT"
  } >&3
}

local_main() {
  [[ $# -gt 0 ]] || { usage >&2; exit 2; }
  SSH_TARGET="$1"; shift
  [[ "$SSH_TARGET" != -* && "$SSH_TARGET" != *[[:space:]]* ]] || fail 'first argument must be an SSH target such as root@203.0.113.10'

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

  [[ -n "$CLIENT_NAME" ]] || fail '--client-name is required'
  [[ "$CLIENT_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || fail 'Invalid client name.'
  [[ -z "$CLIENT_ADDRESS" ]] || validate_ipv4_cidr "$CLIENT_ADDRESS" || fail "Invalid IPv4 --client-address: $CLIENT_ADDRESS"
  validate_ipv4_cidr "$SERVER_ADDRESS" || fail "Invalid IPv4 --server-address: $SERVER_ADDRESS"
  command -v ssh >/dev/null 2>&1 || fail 'ssh is required on the local machine'

  [[ -n "$ENDPOINT" ]] || ENDPOINT="${SSH_TARGET#*@}"
  [[ -n "$ENDPOINT" ]] || fail 'cannot infer endpoint from SSH target; pass --endpoint'

  remote_args=(--endpoint "$ENDPOINT" --interface "$WG_IF" --listen-port "$LISTEN_PORT" --server-address "$SERVER_ADDRESS" --client-name "$CLIENT_NAME")
  [[ -z "$CLIENT_ADDRESS" ]] || remote_args+=(--client-address "$CLIENT_ADDRESS")
  [[ -z "$WAN_IF" ]] || remote_args+=(--wan-interface "$WAN_IF")
  [[ -z "$DNS" ]] || remote_args+=(--dns "$DNS")
  printf -v quoted_remote_args '%q ' "${remote_args[@]}"

  remote_user=""
  [[ "$SSH_TARGET" != *@* ]] || remote_user="${SSH_TARGET%@*}"
  if [[ "$remote_user" == root ]]; then
    remote_command="RBS_WG_REMOTE_MODE=1 bash -s -- ${quoted_remote_args}"
  else
    remote_command="sudo -n env RBS_WG_REMOTE_MODE=1 bash -s -- ${quoted_remote_args}"
  fi

  tmp_config="$(mktemp)"
  trap 'rm -f "$tmp_config"' EXIT
  printf 'Provisioning WireGuard on %s...\n' "$SSH_TARGET" >&2
  ssh -T "$SSH_TARGET" "$remote_command" < "$0" > "$tmp_config" || fail "remote WireGuard provisioning failed on $SSH_TARGET"
  [[ -s "$tmp_config" ]] || fail 'remote installer returned an empty client configuration'

  if [[ -n "$OUTPUT" ]]; then
    umask 077
    mkdir -p "$(dirname "$OUTPUT")"
    cp "$tmp_config" "$OUTPUT"
    chmod 0600 "$OUTPUT"
    printf 'Client config saved locally: %s\n' "$OUTPUT" >&2
  fi
  printf '\nWireGuard client config for %s:\n' "$CLIENT_NAME" >&2
  cat "$tmp_config"
}

if [[ "${RBS_WG_TEST_LIB:-0}" != 1 ]]; then
  if [[ "${RBS_WG_REMOTE_MODE:-0}" == 1 ]]; then remote_install "$@"; else local_main "$@"; fi
fi
