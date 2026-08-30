#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
script="scripts/install-wireguard-server.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -f "$script" ]] || fail "missing $script"

grep -q 'EUID' "$script" || fail 'installer must require root'
grep -q '/etc/os-release' "$script" || fail 'installer must detect host OS'
grep -q 'wireguard-tools' "$script" || fail 'installer must install wireguard-tools'
grep -q 'nftables' "$script" || fail 'installer must install nftables'
grep -q 'net.ipv4.ip_forward=1' "$script" || fail 'installer must persist IPv4 forwarding'
grep -q 'table inet rbs_wg' "$script" || fail 'installer must own only the rbs_wg nftables table'
grep -q 'masquerade' "$script" || fail 'installer must configure NAT masquerade'
grep -q 'ct state established,related accept' "$script" || fail 'installer must allow established return forwarding'
grep -q 'wg-quick@' "$script" || fail 'installer must enable wg-quick service'
grep -q '# rbs-client:' "$script" || fail 'installer must mark generated peers'
grep -q 'AllowedIPs = 0.0.0.0/0' "$script" || fail 'generated client must be full-tunnel'
grep -q 'PersistentKeepalive = 25' "$script" || fail 'generated client must keep NAT mappings alive'
grep -Fq "KEY_DIR=\"\$WG_DIR/rbs-keys\"" "$script" || fail 'installer must persist generated peer material under /etc/wireguard/rbs-keys'
grep -q '^validate_ipv4_cidr()' "$script" || fail 'installer must validate IPv4 CIDRs structurally'
grep -q 'prefix > 32' "$script" || fail 'installer must reject IPv4 prefixes above /32'
grep -q 'octet > 255' "$script" || fail 'installer must reject IPv4 octets above 255'
grep -Fq 'wg pubkey < "$SERVER_PRIVATE" > "$SERVER_PUBLIC"' "$script" || fail 'installer must regenerate a missing server public key from the private key'
grep -Fq 'wg pubkey < "$CLIENT_PRIVATE" > "$CLIENT_PUBLIC"' "$script" || fail 'installer must regenerate a missing client public key from the private key'
! grep -q 'flush ruleset' "$script" || fail 'installer must not flush unrelated nftables rules'

printf 'WireGuard server static contract: PASS\n'
