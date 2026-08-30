#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

required=(
  compose.yaml
  browser/Dockerfile
  browser/entrypoint.sh
  .gitignore
  .env.account.example
  config/wireguard.example.conf
  rbs
  scripts/bootstrap-debian.sh
)

for path in "${required[@]}"; do
  [[ -f "$path" ]] || fail "missing $path"
done

grep -Eq "network_mode:[[:space:]]*[\"']?service:vpn" compose.yaml || fail 'browser must share vpn network namespace'
! grep -Eq "network_mode:[[:space:]]*[\"']?host" compose.yaml || fail 'host networking is forbidden'
! grep -Eq 'privileged:[[:space:]]*true' compose.yaml || fail 'privileged containers are forbidden'
grep -q 'FIREWALL_INPUT_PORTS' compose.yaml || fail 'Gluetun Xpra input firewall allowance is required'
grep -q '127.0.0.1' .env.account.example || fail 'Xpra sample bind must default to loopback'
grep -q 'state/' .gitignore || fail 'runtime state must be ignored'
! grep -R --line-number --fixed-strings -- '--no-sandbox' browser compose.yaml rbs || fail 'Chromium sandbox must stay enabled'
grep -Eq '^[[:space:]]+chromium-sandbox[[:space:]]*\\?$' browser/Dockerfile || fail 'Debian Chromium sandbox package is required'
grep -Eq '^[[:space:]]+xpra-x11[[:space:]]*\\?$' browser/Dockerfile || fail 'xpra-x11 is required for Xpra seamless mode'

grep -q "case \"\$command\" in" rbs || fail 'rbs command dispatcher missing'
for command in create up down logs status ip connect doctor; do
  grep -Eq "(^|[|[:space:]])${command}([)|[:space:]])" rbs || fail "rbs command missing: $command"
done
grep -q 'PLACEHOLDER_PRIVATE_KEY' rbs || fail 'rbs must reject the example private key'

grep -q 'VERSION_CODENAME' scripts/bootstrap-debian.sh || fail 'bootstrap must validate Debian codename'
grep -q 'download.docker.com/linux/debian' scripts/bootstrap-debian.sh || fail 'bootstrap must use Docker Debian repository'
grep -q 'docker-compose-plugin' scripts/bootstrap-debian.sh || fail 'bootstrap must install Compose plugin'
! grep -Eqi 'gnome|kde|xfce|lightdm|gdm' scripts/bootstrap-debian.sh || fail 'bootstrap must remain headless'

# Guard against accidentally committing common real WireGuard secret assignments.
while IFS= read -r file; do
  case "$file" in
    config/wireguard.example.conf|docs/*|README.md) continue ;;
  esac
  if grep -Eq '^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*[A-Za-z0-9+/]{40,}={0,2}[[:space:]]*$' "$file"; then
    fail "possible WireGuard private key committed in $file"
  fi
done < <(git ls-files)

printf 'Static security contract: PASS\n'
