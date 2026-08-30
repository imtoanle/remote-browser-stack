# Chrome Stable and WireGuard Integration Design

## Goal

Extend the initial remote-browser stack so the default browser is Google Chrome Stable, external WireGuard exit servers can be provisioned reproducibly, and CI proves the Gluetun/WireGuard path fails closed when the tunnel is unavailable.

## Scope

This change adds three tightly related capabilities to the existing stack:

1. Replace Debian Chromium with Google Chrome Stable as the default remote browser while preserving the existing non-root Xpra runtime and Chromium-family sandbox hardening.
2. Add a native external WireGuard server installer for Debian/Ubuntu that configures WireGuard, IPv4 forwarding, nftables forwarding/NAT, and emits a Gluetun-compatible client configuration.
3. Add an integration test that creates a real WireGuard tunnel and Gluetun network namespace, proves traffic succeeds while the tunnel is healthy, then removes the server-side WireGuard path and proves the client namespace cannot fall back to the Docker/host Internet path.

## Browser design

The browser image remains Debian 13 slim plus Xpra. Google Chrome Stable is installed from Google's official Debian repository for amd64 using a dedicated keyring and `signed-by` source entry. The launcher changes from `chromium` to `google-chrome-stable` and keeps a persistent profile at `/home/browser/profile`.

Chrome continues to run as uid 1000 with all outer container capabilities dropped, `no-new-privileges` enabled, Docker AppArmor disabled only for the browser container because Docker's default AppArmor profile blocks Chrome's user-namespace sandbox, and the repository's Moby-derived seccomp profile permits the minimal namespace/chroot syscalls proven necessary by runtime tests. `--no-sandbox`, privileged mode, and `SYS_ADMIN` remain forbidden.

## External WireGuard server design

`scripts/install-wireguard-server.sh` targets Debian 12/13 and Ubuntu 22.04/24.04 or newer compatible releases. It is root-only and idempotent.

Inputs are supplied through flags so it is usable both interactively and from automation:

- `--endpoint <public-host-or-ip>`: public endpoint clients should use.
- `--interface <name>`: defaults to `wg0`.
- `--listen-port <port>`: defaults to `51820`.
- `--server-address <cidr>`: defaults to `10.77.0.1/24`.
- `--client-name <name>`: required when creating a client.
- `--client-address <cidr>`: required, for example `10.77.0.2/32`.
- `--output <path>`: client configuration destination; defaults to `/root/<client-name>.conf`.
- `--wan-interface <name>`: optional; otherwise inferred from the default route.
- `--dns <ip>`: optional client DNS entry.

The script installs `wireguard-tools`, `nftables`, and supporting packages; generates the server key once under `/etc/wireguard`; creates or updates `/etc/wireguard/<interface>.conf`; enables `net.ipv4.ip_forward=1` persistently; and manages a dedicated nftables table named `inet rbs_wg` rather than overwriting the host's entire firewall.

The nftables rules allow forwarding from the WireGuard interface to the selected WAN interface, allow established/related return traffic, and masquerade the WireGuard subnet on egress. `nftables.service` and `wg-quick@<interface>` are enabled. Re-running with the same client does not duplicate peers or firewall rules.

The emitted client configuration is directly usable as Gluetun's custom WireGuard file and contains `[Interface] PrivateKey`, `Address`, optional `DNS`, and `[Peer] PublicKey`, `Endpoint`, `AllowedIPs = 0.0.0.0/0`, and `PersistentKeepalive = 25`.

## Kill-switch integration test design

The test must verify behavior, not only configuration text.

On a trusted self-hosted Linux runner with Docker, `/dev/net/tun`, and WireGuard kernel support, the test creates a temporary WireGuard server namespace/container and a Gluetun client container using a generated client configuration. A tiny probe container shares Gluetun's network namespace with `network_mode: service:vpn`.

Phase A (healthy tunnel):

- Bring up the WireGuard server and Gluetun client.
- Wait for a successful handshake.
- Confirm the probe can reach a test endpoint through the tunnel.
- Record that Gluetun reports a healthy VPN path.

Phase B (tunnel failure):

- Stop/remove the server-side WireGuard endpoint while leaving Gluetun and the probe running.
- Wait for the tunnel to become unusable.
- Assert the probe cannot reach the test endpoint.
- Assert the probe has no usable direct fallback route through Docker/host Internet.

The test uses only disposable RFC1918 addressing and generated ephemeral keys. No real production WireGuard credentials or public VPN service is used.

## CI

The existing self-hosted CI keeps workflow-level concurrency with `cancel-in-progress: true`. A new `network-integration` job runs only for trusted branches/PRs from the same repository, matching the existing public-repository self-hosted-runner safety rule.

Runner prerequisites are checked explicitly: Docker, Docker Compose, `wg`, `ip`, `curl`, `/dev/net/tun`, and permission to create the required Docker networking resources. If the runner lacks a prerequisite, the job fails with a clear message rather than silently skipping the kill-switch test.

## Security invariants

- Browser traffic has no Docker network of its own and shares Gluetun's network namespace.
- No production path uses `--no-sandbox`, `seccomp=unconfined`, `privileged`, or `SYS_ADMIN`.
- Google Chrome profile data is persistent per browser account and never shared between accounts.
- WireGuard private keys and generated client configs live outside tracked repository paths; tests use ephemeral keys only.
- External WireGuard server rules are isolated in a dedicated nftables table and do not flush unrelated host firewall state.
- If WireGuard is unavailable, the browser/probe must lose Internet access instead of falling back to the VM/host public IP.

## Non-goals

- Firefox support in this change.
- Anti-detect or fingerprint spoofing.
- Web UI for managing WireGuard peers.
- Provisioning the external cloud/VPS itself.
- IPv6 tunneling; IPv6 remains out of scope until an explicit IPv6 design is added.
