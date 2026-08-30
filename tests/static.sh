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
  browser/start-browser.sh
  .gitignore
  .env.account.example
  config/wireguard.example.conf
  rbs
  scripts/bootstrap-debian.sh
  scripts/install-seccomp-profile.sh
  scripts/install-wireguard-server.sh
  scripts/add-wireguard-peer.sh
  tests/xpra-password.sh
  tests/chrome-profile-lock.sh
  tests/wireguard-server-static.sh
  tests/add-wireguard-peer-static.sh
  tests/integration/Dockerfile.wireguard-server
  tests/integration/wireguard-killswitch.sh
)

for path in "${required[@]}"; do
  [[ -f "$path" ]] || fail "missing $path"
done

grep -Eq "network_mode:[[:space:]]*[\"']?service:vpn" compose.yaml || fail 'browser must share vpn network namespace'
! grep -Eq "network_mode:[[:space:]]*[\"']?host" compose.yaml || fail 'host networking is forbidden'
! grep -Eq 'privileged:[[:space:]]*true' compose.yaml || fail 'privileged containers are forbidden'
! grep -q 'SYS_ADMIN' compose.yaml || fail 'SYS_ADMIN is forbidden; Chrome must use its user-namespace sandbox'
grep -q 'no-new-privileges:true' compose.yaml || fail 'browser must use no-new-privileges with the user-namespace sandbox'
grep -q 'apparmor=unconfined' compose.yaml || fail 'browser must bypass docker-default AppArmor so Chrome user namespaces can initialize'
grep -Fq "seccomp=\${SECCOMP_PROFILE}" compose.yaml || fail 'browser must use the pinned Chrome seccomp profile'
! grep -R --line-number -E 'seccomp[=:][[:space:]]*unconfined' compose.yaml scripts rbs || fail 'unconfined seccomp is forbidden in production runtime paths'
grep -q 'FIREWALL_INPUT_PORTS' compose.yaml || fail 'Gluetun Xpra input firewall allowance is required'
grep -qx 'XPRA_BIND_IP=0.0.0.0' .env.account.example || fail 'Xpra sample bind must default to all VM interfaces for trusted-LAN access'
grep -Fq 'XPRA_BIND_IP=0.0.0.0' rbs || fail 'new accounts must expose Xpra on VM interfaces for trusted-LAN access'
grep -Fq 'xpra attach tcp://BROWSER_VM_LAN_IP:' rbs || fail 'rbs connect must show direct LAN attach guidance when bound to 0.0.0.0'
grep -q 'trusted LAN' README.md || fail 'README must document trusted-LAN Xpra access'
! grep -q 'default loopback binding' README.md || fail 'README must not describe loopback as the default Xpra binding'
grep -q 'state/' .gitignore || fail 'runtime state must be ignored'
! grep -R --line-number --fixed-strings -- '--no-sandbox' browser compose.yaml rbs || fail 'disabling the Chrome sandbox is forbidden'
! grep -q -- '--disable-setuid-sandbox' browser/start-browser.sh || fail 'Chrome launcher must not use the unsupported --disable-setuid-sandbox flag'
grep -q -- '--dpi=96' browser/entrypoint.sh || fail 'Xpra must start at a deterministic 96 DPI'
! grep -q -- '--file-transfer=no' browser/entrypoint.sh || fail 'Xpra 6.5.3 client crashes when the file capability is omitted by --file-transfer=no'
grep -Eq '^[[:space:]]+google-chrome-stable[[:space:]]*\\?$' browser/Dockerfile || fail 'browser image must install Google Chrome Stable'
! grep -Eq '^[[:space:]]+chromium[[:space:]]*\\?$' browser/Dockerfile || fail 'Debian Chromium package must not be the default browser'
grep -q 'google-chrome-stable' browser/start-browser.sh || fail 'browser launcher must execute Google Chrome Stable'
grep -q 'dl.google.com/linux/chrome/deb' browser/Dockerfile || fail 'Chrome must come from the official Google Debian repository'
grep -Eq '^[[:space:]]+xpra-x11[[:space:]]*\\?$' browser/Dockerfile || fail 'xpra-x11 is required for Xpra seamless mode'

grep -q 'amd64-only' README.md || fail 'README must document the current amd64-only Chrome image'
grep -q 'Google Chrome Stable' README.md || fail 'README must describe Google Chrome Stable as the default browser'
! grep -q "Both \`amd64\` and \`arm64\`" README.md || fail 'README must not claim unsupported Chrome ARM64 support'

grep -q '3c28324314729dbade8287e868eef6338c42807a' scripts/install-seccomp-profile.sh \
  || fail 'Chrome seccomp base must be pinned to the reviewed Moby profile commit'
grep -q 'moby/profiles' scripts/install-seccomp-profile.sh || fail 'seccomp installer must use the current Moby profile as its base'
for syscall in clone setns unshare chroot; do
  grep -q "$syscall" scripts/install-seccomp-profile.sh || fail "seccomp installer must allow Chrome sandbox syscall: $syscall"
done
for syscall in clone3 openat2 pidfd_open; do
  grep -q "$syscall" scripts/install-seccomp-profile.sh || fail "seccomp installer must verify modern profile syscall: $syscall"
done

grep -q "case \"\$command\" in" rbs || fail 'rbs command dispatcher missing'
for command in create up down logs status ip connect doctor; do
  grep -Eq "(^|[|[:space:]])${command}([)|[:space:]])" rbs || fail "rbs command missing: $command"
done
grep -q 'PLACEHOLDER_PRIVATE_KEY' rbs || fail 'rbs must reject the example private key'
grep -q 'ensure_seccomp_profile' rbs || fail 'rbs up must provision the Chrome seccomp profile'
grep -Fq "bash \"\$ROOT_DIR/scripts/install-seccomp-profile.sh\"" rbs \
  || fail 'rbs must invoke the seccomp installer through bash so checkout mode bits cannot break startup'

grep -q 'VERSION_CODENAME' scripts/bootstrap-debian.sh || fail 'bootstrap must validate Debian codename'
grep -q 'download.docker.com/linux/debian' scripts/bootstrap-debian.sh || fail 'bootstrap must use Docker Debian repository'
grep -q 'docker-compose-plugin' scripts/bootstrap-debian.sh || fail 'bootstrap must install Compose plugin'
grep -Eq '^[[:space:]]+jq[[:space:]]*\\?$' scripts/bootstrap-debian.sh || fail 'bootstrap must install jq for seccomp profile generation'
! grep -Eqi 'gnome|kde|xfce|lightdm|gdm' scripts/bootstrap-debian.sh || fail 'bootstrap must remain headless'

bash tests/xpra-password.sh >/dev/null || fail 'Xpra password generation contract failed'
bash tests/chrome-profile-lock.sh >/dev/null || fail 'Chrome profile stale-lock cleanup contract failed'
bash tests/wireguard-server-static.sh >/dev/null || fail 'WireGuard server static contract failed'
bash tests/add-wireguard-peer-static.sh >/dev/null || fail 'WireGuard peer lifecycle contract failed'
grep -q 'network_mode: service:vpn' docs/superpowers/specs/2026-08-30-chrome-wireguard-integration-design.md || fail 'design must preserve browser-vpn namespace sharing'
grep -q 'Phase B:' tests/integration/wireguard-killswitch.sh || fail 'kill-switch test must include a tunnel failure phase'
grep -q 'docker stop.*server' tests/integration/wireguard-killswitch.sh || fail 'kill-switch test must stop the WireGuard server'
grep -q 'direct fallback leaked' tests/integration/wireguard-killswitch.sh || fail 'kill-switch test must fail on direct fallback'

grep -q '^concurrency:' .github/workflows/ci.yml || fail 'CI must define workflow-level concurrency'
grep -q 'cancel-in-progress:[[:space:]]*true' .github/workflows/ci.yml || fail 'CI must cancel obsolete runs when a new commit arrives'
grep -Fq 'bash ./scripts/install-seccomp-profile.sh' .github/workflows/ci.yml \
  || fail 'CI must invoke the seccomp installer through bash'
grep -q '^  network-integration:' .github/workflows/ci.yml || fail 'CI must run the WireGuard network integration job'
grep -Fq 'bash tests/integration/wireguard-killswitch.sh' .github/workflows/ci.yml || fail 'CI must execute the kill-switch integration test'

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
