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
account_dir="$state_dir/account-test"
password_file="$account_dir/xpra-password"

[[ -f "$password_file" ]] || fail 'rbs create did not generate xpra-password'

byte_count="$(wc -c < "$password_file")"
[[ "$byte_count" -eq 48 ]] || fail "Xpra password must be exactly 48 bytes without a trailing newline; got $byte_count bytes"

if LC_ALL=C grep -q $'[\r\n]' "$password_file"; then
  fail 'Xpra password must not contain CR/LF characters because Xpra auth=file reads them as part of the password'
fi

[[ "$(cat "$password_file")" =~ ^[0-9a-f]{48}$ ]] || fail 'Xpra password must remain a 48-character lowercase hex token'

account_mode="$(stat -c '%a' "$account_dir")"
[[ "$account_mode" == '700' ]] || fail "account directory must remain host-private (0700); got $account_mode"

password_mode="$(stat -c '%a' "$password_file")"
[[ "$password_mode" == '644' ]] || fail "Xpra password must be readable by the non-root container through Compose's file bind mount; got $password_mode"

printf 'Xpra password generation contract: PASS\n'
