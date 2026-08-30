FROM debian:13-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      dbus-x11 \
      gnupg \
      wget \
    && wget -qO /usr/share/keyrings/xpra.asc https://xpra.org/xpra.asc \
    && wget -qO /etc/apt/sources.list.d/xpra.sources \
      https://raw.githubusercontent.com/Xpra-org/xpra/master/packaging/repos/trixie/xpra.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
      chromium \
      fonts-liberation \
      fonts-noto-color-emoji \
      xauth \
      xpra \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 1000 --shell /bin/bash browser \
    && install -d -o browser -g browser -m 0700 /home/browser/profile /home/browser/.xpra

COPY --chmod=0755 entrypoint.sh /usr/local/bin/browser-entrypoint
COPY --chmod=0755 start-browser.sh /usr/local/bin/start-browser

USER browser
WORKDIR /home/browser

ENTRYPOINT ["/usr/local/bin/browser-entrypoint"]
