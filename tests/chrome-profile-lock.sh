#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/home/profile" "$tmp/bin"
for lock in SingletonLock SingletonCookie SingletonSocket; do
  : > "$tmp/home/profile/$lock"
done

cat > "$tmp/bin/dbus-run-session" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/bin/dbus-run-session"

HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash browser/start-browser.sh

for lock in SingletonLock SingletonCookie SingletonSocket; do
  [[ ! -e "$tmp/home/profile/$lock" ]] || fail "stale Chrome lock was not removed: $lock"
done

printf 'Chrome profile lock cleanup: PASS\n'
