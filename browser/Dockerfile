FROM debian:13-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      dbus-x11 \
      gnupg \
      wget \
    && curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
      | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
    && printf '%s\n' \
      'deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main' \
      > /etc/apt/sources.list.d/google-chrome.list \
    && wget -qO /usr/share/keyrings/xpra.asc https://xpra.org/xpra.asc \
    && wget -qO /etc/apt/sources.list.d/xpra.sources \
      https://raw.githubusercontent.com/Xpra-org/xpra/master/packaging/repos/trixie/xpra.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
      google-chrome-stable \
      fonts-liberation \
      fonts-noto-color-emoji \
      xauth \
      xpra \
      xpra-x11 \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 1000 --shell /bin/bash browser \
    && install -d -o browser -g browser -m 0700 /home/browser/profile /home/browser/.xpra

COPY --chmod=0755 entrypoint.sh /usr/local/bin/browser-entrypoint
COPY --chmod=0755 start-browser.sh /usr/local/bin/start-browser

USER browser
WORKDIR /home/browser

ENTRYPOINT ["/usr/local/bin/browser-entrypoint"]
