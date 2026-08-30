#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${RBS_SECCOMP_PROFILE:-$ROOT_DIR/state/security/chromium-seccomp.json}"
MOBY_PROFILES_COMMIT="3c28324314729dbade8287e868eef6338c42807a"
SOURCE_URL="https://raw.githubusercontent.com/moby/profiles/${MOBY_PROFILES_COMMIT}/seccomp/default.json"

for command in curl jq; do
  command -v "$command" >/dev/null 2>&1 || {
    printf '%s is required to install the Chromium seccomp profile\n' "$command" >&2
    exit 1
  }
done

if [[ -s "$DEST" ]]; then
  printf '%s\n' "$DEST"
  exit 0
fi

mkdir -p "$(dirname "$DEST")"
tmp="$(mktemp)"
patched="$(mktemp)"
trap 'rm -f "$tmp" "$patched"' EXIT

curl -fsSL "$SOURCE_URL" -o "$tmp"

jq -e '.defaultAction == "SCMP_ACT_ERRNO"' "$tmp" >/dev/null || {
  printf 'Downloaded Moby seccomp profile has an unexpected default action\n' >&2
  exit 1
}
# Guard that we received the modern profile rather than an old/stale shape.
for syscall in clone3 openat2 pidfd_open; do
  jq -e --arg syscall "$syscall" '.syscalls[]?.names[]? | select(. == $syscall)' "$tmp" >/dev/null || {
    printf 'Downloaded Moby seccomp profile is missing modern syscall: %s\n' "$syscall" >&2
    exit 1
  }
done

# Moby intentionally gates namespace-changing syscalls behind CAP_SYS_ADMIN.
# Chromium's user-namespace sandbox needs these three operations while the
# outer container deliberately drops every capability. Add one narrow allow
# rule and retain the rest of Moby's current default profile unchanged.
jq '
  .syscalls = ([{
    "names": ["clone", "setns", "unshare"],
    "action": "SCMP_ACT_ALLOW",
    "args": [],
    "comment": "Allow Chromium user-namespace sandbox without CAP_SYS_ADMIN",
    "includes": {},
    "excludes": {}
  }] + .syscalls)
' "$tmp" > "$patched"

for syscall in clone setns unshare; do
  jq -e --arg syscall "$syscall" '
    .syscalls[]
    | select(.action == "SCMP_ACT_ALLOW" and (.includes == {}) and (.excludes == {}))
    | .names[]
    | select(. == $syscall)
  ' "$patched" >/dev/null || {
    printf 'Patched seccomp profile does not unconditionally allow: %s\n' "$syscall" >&2
    exit 1
  }
done

install -m 0644 "$patched" "$DEST"
printf '%s\n' "$DEST"
