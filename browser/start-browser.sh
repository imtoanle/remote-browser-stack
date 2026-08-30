#!/usr/bin/env bash
set -euo pipefail

profile_dir="$HOME/profile"

# The browser profile is persisted across container recreation, while Docker
# gives each recreated container a new hostname. Chrome's singleton symlinks
# can therefore point at a process/host that no longer exists and prevent the
# only browser instance for this account from starting.
rm -f \
  "$profile_dir/SingletonLock" \
  "$profile_dir/SingletonCookie" \
  "$profile_dir/SingletonSocket"

chrome_args=(
  --user-data-dir="$profile_dir"
  --no-first-run
  --no-default-browser-check
  --restore-last-session
)

if [[ -n "${START_URL:-}" ]]; then
  chrome_args+=("$START_URL")
fi

exec dbus-run-session -- google-chrome-stable "${chrome_args[@]}"
