#!/usr/bin/env bash
# shellcheck disable=SC2317
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

state_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$state_dir"
}
trap cleanup EXIT

export RBS_WG_TEST_LIB=1
# shellcheck disable=SC1091
source ./scripts/install-wireguard-server.sh

key_dir="$state_dir/rbs-keys"
mkdir -p "$key_dir"

address="$(select_client_address account-01 '' 10.77.0.1/24 "$key_dir")"
[[ "$address" == '10.77.0.2/32' ]] || fail "first client should receive 10.77.0.2/32, got $address"
printf '%s\n' "$address" > "$key_dir/client-account-01.address"

address="$(select_client_address account-02 '' 10.77.0.1/24 "$key_dir")"
[[ "$address" == '10.77.0.3/32' ]] || fail "second client should receive 10.77.0.3/32, got $address"
printf '%s\n' "$address" > "$key_dir/client-account-02.address"

address="$(select_client_address account-01 '' 10.77.0.1/24 "$key_dir")"
[[ "$address" == '10.77.0.2/32' ]] || fail "rerun must preserve account-01 address, got $address"

if select_client_address account-03 '10.77.0.2/32' 10.77.0.1/24 "$key_dir" >/dev/null 2>&1; then
  fail 'explicit address already owned by another client must be rejected'
fi

address="$(select_client_address account-03 '10.77.0.4/32' 10.77.0.1/24 "$key_dir")"
[[ "$address" == '10.77.0.4/32' ]] || fail "unused explicit address should be accepted, got $address"

printf 'WireGuard address allocation contract: PASS\n'
