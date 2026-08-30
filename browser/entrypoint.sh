#!/usr/bin/env bash
set -euo pipefail

password_file=/run/secrets/xpra_password

if [[ ! -s "$password_file" ]]; then
  printf 'Xpra password secret is missing or empty: %s\n' "$password_file" >&2
  exit 1
fi

export XDG_RUNTIME_DIR="$HOME/.runtime"
install -d -m 0700 "$HOME/profile" "$HOME/.xpra" "$XDG_RUNTIME_DIR"

exec xpra seamless :100 \
  --daemon=no \
  --exit-with-children=yes \
  --bind=noabstract \
  --bind-tcp="0.0.0.0:14500,auth=file(filename=${password_file})" \
  --html=no \
  --mdns=no \
  --pulseaudio=no \
  --notifications=no \
  --printing=no \
  --webcam=no \
  --file-transfer=no \
  --start-child=/usr/local/bin/start-browser
