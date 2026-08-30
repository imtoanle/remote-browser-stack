#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${RBS_SECCOMP_PROFILE:-$ROOT_DIR/state/security/chromium-seccomp.json}"
PLAYWRIGHT_COMMIT="ae935a43d9e376e4759548f6b3c6905c7b282333"
SOURCE_URL="https://raw.githubusercontent.com/microsoft/playwright/${PLAYWRIGHT_COMMIT}/utils/docker/seccomp_profile.json"

command -v curl >/dev/null 2>&1 || {
  printf 'curl is required to install the Chromium seccomp profile\n' >&2
  exit 1
}

if [[ -s "$DEST" ]]; then
  printf '%s\n' "$DEST"
  exit 0
fi

mkdir -p "$(dirname "$DEST")"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

curl -fsSL "$SOURCE_URL" -o "$tmp"

grep -q '"defaultAction": "SCMP_ACT_ERRNO"' "$tmp" || {
  printf 'Downloaded seccomp profile has an unexpected default action\n' >&2
  exit 1
}
for syscall in clone setns unshare; do
  grep -q "\"${syscall}\"" "$tmp" || {
    printf 'Downloaded seccomp profile is missing required syscall: %s\n' "$syscall" >&2
    exit 1
  }
done

install -m 0644 "$tmp" "$DEST"
printf '%s\n' "$DEST"
