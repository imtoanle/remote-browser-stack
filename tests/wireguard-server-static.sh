#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
script="scripts/install-wireguard-server.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -f "$script" ]] || fail "missing $script"

grep -q 'ssh' "$script" || fail 'installer must orchestrate provisioning over SSH from the local machine'
grep -q 'RBS_WG_REMOTE_MODE' "$script" || fail 'installer must stream itself into a dedicated remote execution mode'
grep -q 'RBS_WG_TEST_LIB' "$script" || fail 'installer must expose address allocation helpers for behavior tests'
grep -q '^select_client_address()' "$script" || fail 'installer must auto-select non-conflicting client addresses'
grep -q '/etc/os-release' "$script" || fail 'remote installer must detect host OS'
grep -q 'wireguard-tools' "$script" || fail 'remote installer must install wireguard-tools'
grep -q 'nftables' "$script" || fail 'remote installer must install nftables'
grep -q 'net.ipv4.ip_forward=1' "$script" || fail 'remote installer must persist IPv4 forwarding'
grep -q 'table inet rbs_wg' "$script" || fail 'remote installer must own only the rbs_wg nftables table'
grep -q 'masquerade' "$script" || fail 'remote installer must configure NAT masquerade'
grep -q 'ct state established,related accept' "$script" || fail 'remote installer must allow established return forwarding'
grep -q 'wg-quick@' "$script" || fail 'remote installer must enable wg-quick service'
grep -q '# rbs-client:' "$script" || fail 'remote installer must mark generated peers'
grep -q 'AllowedIPs = 0.0.0.0/0' "$script" || fail 'generated client must be full-tunnel'
grep -q 'PersistentKeepalive = 25' "$script" || fail 'generated client must keep NAT mappings alive'
grep -Fq "KEY_DIR=\"\$WG_DIR/rbs-keys\"" "$script" || fail 'installer must persist generated peer material under /etc/wireguard/rbs-keys'
grep -q '^validate_ipv4_cidr()' "$script" || fail 'installer must validate IPv4 CIDRs structurally'
grep -q 'prefix > 32' "$script" || fail 'installer must reject IPv4 prefixes above /32'
grep -q 'octet > 255' "$script" || fail 'installer must reject IPv4 octets above 255'
grep -q 'rbs-server.env' "$script" || fail 'installer must persist endpoint/interface metadata for later peer creation'
grep -q 'RBS_ENDPOINT=' "$script" || fail 'persisted server metadata must include the public endpoint'
! grep -q 'flush ruleset' "$script" || fail 'installer must not flush unrelated nftables rules'
# shellcheck disable=SC2016
! grep -Fq '[[ "${EUID}" -eq 0 ]] || { printf '\''Run as root.' "$script" || fail 'local wrapper must not require root'
grep -q -- '--client-address)' "$script" || fail 'explicit client address override must remain supported'
grep -q 'CLIENT_ADDRESS=""' "$script" || fail 'client address must default to automatic allocation'
grep -q 'OUTPUT=""' "$script" || fail 'local output path must be optional'

bash tests/wireguard-address-allocation.sh >/dev/null || fail 'WireGuard address allocation behavior failed'

printf 'WireGuard server static contract: PASS\n'
