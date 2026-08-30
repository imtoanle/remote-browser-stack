#!/usr/bin/env bash
set -euo pipefail

exec dbus-run-session -- chromium \
  --user-data-dir="$HOME/profile" \
  --disable-setuid-sandbox \
  --no-first-run \
  --no-default-browser-check \
  "${START_URL:-about:blank}"
