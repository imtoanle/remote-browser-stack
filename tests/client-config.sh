#!/usr/bin/env bash
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

RBS_STATE_DIR="$state_dir" bash ./rbs create account-test >/dev/null
password="$(cat "$state_dir/account-test/xpra-password")"

RBS_STATE_DIR="$state_dir" bash ./rbs client-config account-test >/dev/null

client_dir="$state_dir/account-test/client"
session_file="$client_dir/account-test.xpra"
password_file="$client_dir/account-test.password"

[[ -f "$session_file" ]] || fail 'client-config must generate an Xpra session file'
[[ -f "$password_file" ]] || fail 'client-config must generate a separate password file'
[[ "$(cat "$password_file")" == "$password" ]] || fail 'client password file must contain the account Xpra password exactly'
[[ "$(stat -c '%a' "$password_file")" == '600' ]] || fail 'client password file must be mode 0600'
[[ "$(stat -c '%a' "$session_file")" == '600' ]] || fail 'client session file must be mode 0600'

grep -qx 'mode=tcp' "$session_file" || fail 'client session must use TCP mode'
grep -qx 'host=BROWSER_VM_LAN_IP' "$session_file" || fail '0.0.0.0 accounts must use an explicit LAN-IP placeholder'
grep -qx 'port=14500' "$session_file" || fail 'client session must use the account Xpra port'
grep -qx 'password-file=~/.config/xpra/rbs/account-test.password' "$session_file" || fail 'client session must reference the portable per-user password path'
grep -qx 'window-close=disconnect' "$session_file" || fail 'client session must disconnect rather than close remote Chrome'
grep -qx 'autoconnect=true' "$session_file" || fail 'client session must autoconnect when opened'

printf 'Client config generation contract: PASS\n'
