#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  printf 'Run this script as root, for example: sudo ./scripts/bootstrap-debian.sh\n' >&2
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "debian" || "${VERSION_CODENAME:-}" != "trixie" ]]; then
  printf 'This bootstrap targets Debian 13 (trixie). Detected: %s %s\n' "${ID:-unknown}" "${VERSION_CODENAME:-unknown}" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

arch="$(dpkg --print-architecture)"
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update
apt-get install -y --no-install-recommends \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin \
  git \
  openssl \
  iproute2

systemctl enable --now docker

if [[ ! -c /dev/net/tun ]]; then
  modprobe tun
fi

if [[ ! -c /dev/net/tun ]]; then
  printf '/dev/net/tun is unavailable after loading the tun module. Check VM/kernel configuration.\n' >&2
  exit 1
fi

cat <<'EOF'
Bootstrap complete.

The VM remains headless; no desktop environment was installed.

Docker's Unix socket is root-owned by default. This script intentionally does not add a user to the docker group because membership is effectively root-equivalent.

Next:
  git clone https://github.com/imtoanle/remote-browser-stack.git
  cd remote-browser-stack
  sudo ./rbs doctor
  ./rbs create account-01
EOF
