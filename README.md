# Remote Browser Stack

Self-hosted remote browser stack with isolated browser profiles, per-account WireGuard routing, and fail-closed network rules.

The stack is designed for a **headless Debian VM** (for example, a small VM on Proxmox). The VM does not need GNOME, KDE, XFCE, Xorg as a host desktop, VNC, or a physical display. Chromium and Xpra run inside containers.

## What this solves

Each account gets an independent persistent browser identity and an independent WireGuard network path:

```text
account-01                      account-02
──────────                      ──────────
Chromium profile 01             Chromium profile 02
      │                               │
Xpra session 01                 Xpra session 02
      │                               │
Gluetun / WireGuard 01          Gluetun / WireGuard 02
      │                               │
public IP 01                    public IP 02
```

The browser container shares the VPN container's network namespace. It does **not** have an independent Docker network interface, so there is no normal host/WAN route for Chromium to fall back to.

If WireGuard goes down, Gluetun's firewall remains active and browser Internet traffic is dropped. Xpra management access can remain reachable so the failure can be inspected.

## Security model

The important invariant is in `compose.yaml`:

```yaml
browser:
  network_mode: "service:vpn"
```

Only the `vpn` service receives `NET_ADMIN` and `/dev/net/tun`. The browser service drops all Linux capabilities, enables `no-new-privileges`, keeps the Chromium sandbox enabled, and publishes no ports.

Xpra is published by the VPN namespace and binds to `127.0.0.1` on the VM by default. The recommended access path is an SSH tunnel instead of exposing plain Xpra TCP to a broader network.

See [docs/security.md](docs/security.md) for the threat model and verification procedure.

## Requirements

- Debian 13 (Trixie) VM
- `/dev/net/tun`
- Docker Engine + Docker Compose v2
- one WireGuard client configuration per browser identity
- Xpra client on the workstation used to control the remote browser

Both `amd64` and `arm64` are supported by Debian Chromium and current Xpra packages. Xpra upstream documents Debian Trixie as a supported stable repository target.

## 1. Prepare a minimal Debian VM

A practical starting point is 2 vCPU, 2-4 GB RAM, and 16+ GB disk for a few browser identities. Actual memory requirements depend mostly on the websites opened in Chromium.

No desktop environment is required.

Clone the repository and run the bootstrap script:

```bash
sudo ./scripts/bootstrap-debian.sh
```

The bootstrap installs Docker Engine and Compose from Docker's signed Debian repository. It intentionally does **not** add your login user to the `docker` group because that group is effectively root-equivalent.

Check the host:

```bash
sudo ./rbs doctor
```

If you intentionally configure rootless Docker or explicit Docker socket access, `./rbs` can be run without `sudo`.

## 2. Create an identity

```bash
sudo ./rbs create account-01
```

This creates private runtime state under:

```text
state/accounts/account-01/
├── account.env
├── wireguard.conf
└── xpra-password
```

`state/` is ignored by Git.

The Chromium profile itself is stored in a Docker named volume scoped to that account's Compose project, so it survives container recreation without host UID/GID problems.

## 3. Add the account's WireGuard configuration

Replace the generated example in:

```text
state/accounts/account-01/wireguard.conf
```

with the real client configuration supplied by your WireGuard/VPN endpoint.

The first version deliberately requires a full IPv4 default route:

```ini
AllowedIPs = 0.0.0.0/0, ::/0
```

`./rbs up` refuses the committed placeholders and refuses a config without `0.0.0.0/0`.

Never put real WireGuard credentials in `config/wireguard.example.conf` or any tracked file.

## 4. Start the browser

```bash
sudo ./rbs up account-01
```

The first start builds the browser image containing Debian 13, Chromium, and Xpra stable.

Check status and the observed public IP:

```bash
sudo ./rbs status account-01
sudo ./rbs ip account-01
```

## 5. Connect with Xpra

By default the generated account binds Xpra to VM loopback only.

Print the connection instructions:

```bash
sudo ./rbs connect account-01
```

From the client computer, create the SSH tunnel shown by the command, for example:

```bash
ssh -N -L 14500:127.0.0.1:14500 USER@BROWSER_VM
```

Then attach with the native Xpra client:

```bash
xpra attach tcp://127.0.0.1:14500/
```

Xpra prompts for the password. On the VM it can be displayed explicitly with:

```bash
sudo ./rbs password account-01
```

Xpra installers for macOS, Windows, and Linux are available from the upstream project: <https://xpra.org/>.

### Direct management-LAN access

If an SSH tunnel is inconvenient and the VM has a trusted management-only interface, edit the account's `account.env` and change:

```dotenv
XPRA_BIND_IP=127.0.0.1
```

to that specific management IP.

Do not use `0.0.0.0` unless you have independently secured the host/network path. Plain TCP is not the preferred way to expose Xpra across an untrusted network.

## Daily commands

```bash
sudo ./rbs status account-01
sudo ./rbs ip account-01
sudo ./rbs logs account-01
sudo ./rbs down account-01
sudo ./rbs up account-01
```

`down` preserves the browser profile volume. A future destructive delete/backup workflow should be explicit rather than hidden behind `down`.

## Multiple accounts

Create another identity:

```bash
sudo ./rbs create account-02
sudo ./rbs up account-02
```

`create` chooses the first unused Xpra host port in `14500-14599`. Each account gets:

- separate Compose project
- separate Gluetun container
- separate WireGuard configuration
- separate Xpra password
- separate persistent Chromium volume
- separate Xpra host port

## Verify the fail-closed behavior

First record the VPN IP:

```bash
sudo ./rbs ip account-01
```

Then deliberately make the WireGuard peer unavailable (for example in a controlled test environment, stop the peer or temporarily provide an unreachable endpoint) and confirm:

1. the Chromium page can no longer reach the Internet;
2. it does not fall back to the Debian VM's public IP;
3. the Xpra session is still reachable through its management port;
4. restoring the VPN restores browser connectivity.

Do this test before trusting a new deployment with a sensitive identity.

## Repository layout

```text
.
├── browser/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── start-browser.sh
├── config/
│   └── wireguard.example.conf
├── docs/
│   └── security.md
├── scripts/
│   └── bootstrap-debian.sh
├── tests/
│   └── static.sh
├── compose.yaml
├── rbs
└── .env.account.example
```

## What this project is not

This project isolates persistent browser data and network routing. It is **not an anti-detect browser** and does not promise that two identities have unrelated browser fingerprints. Hardware, rendering, fonts, timezone, browser version, and other signals may still correlate sessions.

It also does not protect against a malicious Docker administrator or a compromised Debian root account; those actors control the containers and their stored browser data.

## Upstream components

- [Xpra](https://github.com/Xpra-org/xpra) — persistent remote applications / seamless remote GUI
- [Gluetun](https://github.com/qdm12/gluetun) — VPN container and fail-closed firewall
- [Docker Compose](https://docs.docker.com/compose/) — per-account service orchestration
- [Chromium](https://www.chromium.org/) — browser

## License

MIT. See [LICENSE](LICENSE).
