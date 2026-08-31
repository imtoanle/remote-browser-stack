# Remote Browser Stack

Self-hosted remote browser stack with isolated browser profiles, per-account WireGuard routing, and fail-closed network rules.

The stack targets a **headless Debian 13 VM** such as a VM on Proxmox. The VM does not need a desktop environment, VNC, or a physical display. Google Chrome Stable and Xpra run inside containers.

> **Architecture note:** the current Chrome image is **amd64-only** because Google's official Linux Chrome repository publishes the package used here for amd64. ARM64 is not currently supported by this stack.

## What this solves

Each account gets an independent persistent browser profile and an independent VPN namespace:

```text
account-01                      account-02
──────────                      ──────────
Chrome profile 01               Chrome profile 02
      │                               │
Xpra session 01                 Xpra session 02
      │                               │
Gluetun / WireGuard 01          Gluetun / WireGuard 02
      │                               │
public IP 01                    public IP 02
```

The browser service uses `network_mode: service:vpn`, so it has no independent Docker network interface. If WireGuard becomes unavailable, Gluetun's firewall remains active and browser traffic must fail closed instead of falling back to the Debian VM's normal WAN route.

CI verifies this with a real ephemeral WireGuard server, a Gluetun client, and a probe sharing the Gluetun namespace: traffic must work while the tunnel is healthy and fail after the WireGuard endpoint is stopped.

## Security model

Only the VPN service receives `NET_ADMIN` and `/dev/net/tun`. The browser runs non-root, drops all Linux capabilities, enables `no-new-privileges`, retains Chrome's Linux user-namespace and seccomp sandboxing, and publishes no ports directly.

Chrome is launched without `--no-sandbox` or `--disable-setuid-sandbox`. The project forbids privileged browser containers, `SYS_ADMIN`, and `seccomp=unconfined` in production runtime paths.

Xpra is published by the VPN namespace and, by default, Docker publishes each account's Xpra port on `0.0.0.0` so it can be reached directly from a **trusted LAN**. Xpra password authentication remains required. This plain TCP listener must not be forwarded or exposed to the public Internet/WAN. Operators who need encrypted remote transport can still set `XPRA_BIND_IP=127.0.0.1` and use an SSH tunnel.

See [docs/security.md](docs/security.md) for the full threat model.

## Requirements

- x86-64 / amd64 host CPU
- Debian 13 (Trixie) VM
- `/dev/net/tun`
- Docker Engine + Docker Compose v2
- one WireGuard client configuration per browser identity
- Xpra client on the workstation used to control the remote browser

## 1. Prepare the Debian VM

A practical starting point is 2 vCPU, 4 GB RAM, and 16+ GB disk. Increase RAM when several Chrome instances will run concurrently.

```bash
sudo ./scripts/bootstrap-debian.sh
sudo ./rbs doctor
```

The bootstrap installs Docker Engine and Compose from Docker's signed Debian repository and intentionally does not add users to the root-equivalent `docker` group.

## 2. Create an account

```bash
sudo ./rbs create account-01
```

Runtime state is stored under the gitignored directory:

```text
state/accounts/account-01/
├── account.env
├── wireguard.conf
└── xpra-password
```

The Chrome profile itself is stored in a per-account Docker named volume.

## 3. Supply WireGuard connectivity

You can use an existing WireGuard provider/configuration, or provision your own external Debian/Ubuntu exit server with the included native tooling.

### Option A: existing WireGuard config

Replace:

```text
state/accounts/account-01/wireguard.conf
```

with a full-tunnel configuration containing at least:

```ini
AllowedIPs = 0.0.0.0/0
```

`./rbs up` rejects committed placeholders and a configuration without the IPv4 default route.

### Option B: provision an external WireGuard server from your workstation

Run the installer **locally** and point it at the external Debian/Ubuntu server over SSH. The remote host does not need this repository cloned:

```bash
./scripts/install-wireguard-server.sh root@203.0.113.10 \
  --client-name account-01 \
  --output ./account-01.conf
```

By default:

- the SSH host (`203.0.113.10` above) is also used as the public WireGuard endpoint;
- the first unused client address is allocated automatically from the WireGuard subnet (`10.77.0.2/32`, then `.3/32`, and so on);
- re-running the same `--client-name` keeps its existing key and tunnel address;
- `--output` is a **local path** and is written mode `0600`;
- the generated client configuration is also printed to stdout at the end.

If the public endpoint differs from the SSH host, override it explicitly:

```bash
./scripts/install-wireguard-server.sh root@10.0.0.5 \
  --endpoint vpn.example.com \
  --client-name account-01 \
  --output ./account-01.conf
```

You can still request a specific tunnel address when needed:

```bash
./scripts/install-wireguard-server.sh root@203.0.113.10 \
  --client-name account-01 \
  --client-address 10.77.0.20/32 \
  --output ./account-01.conf
```

Explicit addresses must be usable `/32` addresses inside the configured server subnet and are rejected if another client already owns the same IP.

The installer:

- streams itself over SSH instead of requiring a repository checkout on the external server;
- installs `wireguard-tools`, `nftables`, and required system utilities remotely;
- generates and persists server/client key material under `/etc/wireguard/rbs-keys`;
- persists endpoint/interface metadata in `/etc/wireguard/rbs-server.env`;
- automatically allocates a non-conflicting client `/32` from persisted peer state;
- serializes peer allocation/config rebuilds with a remote `flock`, so concurrent provisioning calls cannot claim the same address or overwrite each other's peer list;
- enables persistent IPv4 forwarding;
- manages only the dedicated nftables table `inet rbs_wg`;
- enables `wg-quick@wg0` and nftables;
- emits a Gluetun-compatible full-tunnel client config.

Copy the resulting local config into the matching browser account:

```bash
cp ./account-01.conf state/accounts/account-01/wireguard.conf
```

### Provision another peer on the same exit server

For additional browser profiles, run the same local installer again with a new client name. A new WireGuard key and the next unused tunnel address are assigned automatically:

```bash
./scripts/install-wireguard-server.sh root@203.0.113.10 \
  --client-name account-02 \
  --output ./account-02.conf
```

Then install it into the matching browser account:

```bash
cp ./account-02.conf state/accounts/account-02/wireguard.conf
```

The lower-level `scripts/add-wireguard-peer.sh` remains available for operators already logged into the exit server, but the local `install-wireguard-server.sh` workflow is the recommended path for both the first peer and subsequent peers.

Do **not** copy the exact same WireGuard client config/private key into multiple Gluetun containers. Use one peer per browser profile even when several profiles intentionally share the same external server and public exit IP.

Do not commit generated WireGuard private keys or client configurations.

## 4. Start and inspect the browser

```bash
sudo ./rbs up account-01
sudo ./rbs status account-01
sudo ./rbs ip account-01
```

The first start builds a Debian 13 image containing Google Chrome Stable and Xpra. Xpra uses the Xorg dummy driver rather than Xvfb so the virtual display can maintain correct hardware DPI during client resize; CI verifies the Xdummy/Xpra configuration and browser startup path.

The Chrome profile is persistent. Normal Xpra detach/reconnect leaves Chrome and its open tabs running. If Chrome or the container itself restarts, Chrome uses `--restore-last-session` to restore tabs from the persisted profile. New accounts leave `START_URL` empty by default so restoring a session does not add a blank tab; `./rbs up` also migrates the older generated `START_URL=about:blank` default to empty.

## 5. Connect with Xpra from the LAN

Run this helper **on the Debian browser VM**:

```bash
sudo ./rbs connect account-01
```

New accounts default to:

```env
XPRA_BIND_IP=0.0.0.0
START_URL=
```

From your workstation on the trusted LAN, connect to the Debian VM's LAN IP and the account-specific Xpra port:

```bash
xpra attach --window-close=disconnect tcp://192.168.1.50:14500/
```

`--window-close=disconnect` is intentional: closing the forwarded Chrome window disconnects the Xpra client instead of forwarding a close request to the remote Chrome process. This keeps the browser and its tabs alive for the next attach. A normal client disconnect or client application quit should likewise leave the remote application running; use `sudo ./rbs down account-01` when you actually want to stop the remote stack.

Xpra prompts for the account password. Retrieve it on the VM only when needed:

```bash
sudo ./rbs password account-01
```

For repeat connections, generate a reusable Xpra session file and separate password file:

```bash
sudo ./rbs client-config account-01
```

The generated files are written under `state/accounts/account-01/client/`. Copy both to `~/.config/xpra/rbs/` on the client machine. For the default `XPRA_BIND_IP=0.0.0.0`, edit the generated `.xpra` file once and replace `BROWSER_VM_LAN_IP` with the VM's LAN address. The session file enables `autoconnect=true` and `window-close=disconnect`, and loads the password from the separate mode-0600 password file.

For multiple accounts the VM IP stays the same and only the port changes, for example `14500`, `14501`, `14502`.

Do **not** port-forward these plain Xpra TCP ports from your router or expose them on a public/WAN interface. If you need access across an untrusted network, override the account to `XPRA_BIND_IP=127.0.0.1` and use SSH or another encrypted management tunnel.

## Multiple accounts

```bash
sudo ./rbs create account-02
sudo ./rbs up account-02
```

Each account currently receives:

- a separate Compose project;
- a separate Gluetun container and network namespace;
- a separate WireGuard client configuration and peer key;
- a separate Chrome profile volume;
- a separate Xpra password and host port.

Multiple accounts may use **the same external WireGuard server/public exit IP** while using separate WireGuard peer keys. This is the recommended model when identities should share egress IP but retain independent tunnel/firewall state.

Using the exact same WireGuard client key/config simultaneously from two independent Gluetun containers is not recommended: WireGuard associates one peer public key with its latest observed endpoint, so concurrent copies can cause endpoint roaming/flapping. Sharing one single Gluetun namespace between multiple browsers is technically possible, but is not implemented in v1 and reduces network isolation between those browser identities.

## Verify fail-closed behavior

The CI integration test performs this automatically with disposable keys:

1. establish a real WireGuard handshake;
2. verify Internet access through the WireGuard server;
3. stop the server endpoint while leaving Gluetun/probe running;
4. verify repeated Internet requests fail;
5. verify the probe still shares the Gluetun network namespace and has no independent Docker network.

For a production deployment, also verify the expected exit IP and DNS/WebRTC behavior before using a sensitive browser identity.

## Daily commands

```bash
sudo ./rbs status account-01
sudo ./rbs ip account-01
sudo ./rbs logs account-01
sudo ./rbs client-config account-01
sudo ./rbs down account-01
sudo ./rbs up account-01
```

`down` preserves the account's Chrome profile volume.

## Repository layout

```text
.
├── browser/
├── config/
├── docs/
├── scripts/
│   ├── add-wireguard-peer.sh
│   ├── bootstrap-debian.sh
│   ├── install-seccomp-profile.sh
│   └── install-wireguard-server.sh
├── tests/
│   ├── integration/
│   ├── add-wireguard-peer-static.sh
│   ├── client-config.sh
│   ├── static.sh
│   ├── wireguard-address-allocation.sh
│   └── wireguard-server-static.sh
├── compose.yaml
└── rbs
```

## What this project is not

This project isolates persistent browser data and network routing. It is **not an anti-detect browser** and does not promise unrelated browser fingerprints. Fonts, rendering, screen geometry, timezone, browser version, hardware signals, and other attributes may still correlate sessions.

It also does not protect against a malicious Docker administrator or a compromised Debian root account.

## Upstream components

- [Google Chrome](https://www.google.com/chrome/) — default browser
- [Xpra](https://github.com/Xpra-org/xpra) — persistent remote applications / seamless remote GUI
- [Gluetun](https://github.com/qdm12/gluetun) — VPN container and fail-closed firewall
