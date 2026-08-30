#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
script="scripts/add-wireguard-peer.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -f "$script" ]] || fail "missing $script"

grep -q 'EUID' "$script" || fail 'peer installer must require root'
grep -q -- '--client-name' "$script" || fail 'peer installer must accept --client-name'
grep -q -- '--client-address' "$script" || fail 'peer installer must accept --client-address'
grep -q 'validate_ipv4_cidr' "$script" || fail 'peer installer must validate IPv4 CIDR input'
grep -Fq "KEY_DIR=\"\$WG_DIR/rbs-keys\"" "$script" || fail 'peer installer must reuse persisted WireGuard server state'
grep -Fq "SERVER_PRIVATE=\"\$KEY_DIR/server.key\"" "$script" || fail 'peer installer must reuse the existing server private key'
grep -Fq "CLIENT_PRIVATE=\"\$KEY_DIR/client-\${CLIENT_NAME}.key\"" "$script" || fail 'each peer must have a dedicated private key'
grep -q 'rbs-server.env' "$script" || fail 'peer installer must read persisted server endpoint metadata'
grep -q 'RBS_ENDPOINT' "$script" || fail 'peer installer must use the persisted public endpoint'
grep -q '# rbs-client:' "$script" || fail 'peer installer must write a deterministic peer marker'
grep -q 'AllowedIPs = 0.0.0.0/0' "$script" || fail 'generated peer config must be full-tunnel'
grep -q 'PersistentKeepalive = 25' "$script" || fail 'generated peer config must keep NAT mappings alive'
grep -Eq 'wg syncconf|systemctl (reload-or-restart|restart).*wg-quick@' "$script" || fail 'peer installer must apply updated peer state to the running interface'
! grep -q 'wg genkey.*SERVER_PRIVATE' "$script" || fail 'adding a peer must not create or rotate the server private key'
grep -q 'already assigned' "$script" || fail 'peer installer must reject an address already assigned to another peer'

grep -q 'add-wireguard-peer.sh' README.md || fail 'README must document adding peers after server bootstrap'

printf 'WireGuard peer lifecycle contract: PASS\n'
