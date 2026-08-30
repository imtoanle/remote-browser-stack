# Initial Remote Browser Stack Design

## Goal

Provide a reproducible, public-safe stack for running persistent remote Chromium identities on a headless Debian VM. Each identity must have its own browser profile and WireGuard tunnel, and browser Internet access must fail closed when the tunnel is unavailable.

## Scope

The first release manages the software inside an already-created Debian VM. It does not provision Proxmox VMs, spoof browser fingerprints, provide an anti-detect browser, or implement a multi-user web control plane.

## Architecture

Each browser identity is one Docker Compose project with two services:

- `vpn`: Gluetun using a custom WireGuard configuration. It owns the network namespace, `NET_ADMIN`, `/dev/net/tun`, the Xpra host port mapping, DNS, and the fail-closed firewall.
- `browser`: a non-root Chromium + Xpra container. It uses `network_mode: service:vpn`, so it has no independent Docker interface or fallback route.

The browser container has no published ports and no direct Docker network. Its only network namespace is the VPN service's namespace.

```text
Xpra client
    |
    | SSH tunnel by default
    v
Debian VM 127.0.0.1:<per-account-port>
    |
    v
Gluetun namespace :14500
    |                    \
    | management INPUT   \ outbound
    v                     v
Xpra -> Chromium       wg0 -> Internet
                         |
                         +-- VPN down => Gluetun firewall DROP
```

Gluetun may use the Docker interface only to establish the configured WireGuard peer. Normal browser traffic is only allowed through the VPN interface. The Xpra port is explicitly admitted as an inbound firewall port so management remains available if the VPN tunnel fails.

## Account state

Runtime state is stored under `state/accounts/<name>/` and ignored by Git:

- `account.env`: account name, Xpra host bind address/port, optional start URL.
- `wireguard.conf`: real WireGuard client configuration.
- `xpra-password`: randomly generated Xpra password.

The Chromium profile is stored in a per-Compose-project named volume. This avoids host UID/GID ownership problems while preserving cookies, local storage, extensions, and browser settings across container recreation.

## Access model

The safe default is `XPRA_BIND_IP=127.0.0.1`. Users connect through an SSH local-forward and then attach with the native Xpra client. A trusted management-LAN address can be configured explicitly when direct LAN access is desired.

Plain Xpra TCP must not be published on every host interface by default.

## Browser container

The browser image is based on Debian 13 (Trixie), installs Chromium from Debian security repositories, and installs Xpra stable packages from Xpra's signed repository. Chromium runs as an unprivileged `browser` user and retains its sandbox; `--no-sandbox` is forbidden.

Xpra runs in seamless mode and starts Chromium as its child. Authentication uses an Xpra password file mounted as a Docker secret rather than an environment variable.

## Fail-closed requirements

1. `browser` MUST use `network_mode: service:vpn`.
2. `browser` MUST NOT publish ports or use host networking.
3. `browser` MUST NOT be privileged and MUST NOT request `NET_ADMIN`.
4. Only `vpn` receives `NET_ADMIN` and `/dev/net/tun`.
5. Gluetun firewall remains enabled; no configuration may disable it.
6. No LAN bypass subnet is enabled by default.
7. Xpra binds to loopback by default.
8. Real WireGuard configs, Xpra passwords, and browser state MUST be ignored by Git.
9. Chromium MUST NOT be launched with `--no-sandbox`.

## Operator workflow

The repository exposes a single `./rbs` command:

- `./rbs create <account>` creates private account state, chooses an unused Xpra port, generates an Xpra password, and writes a WireGuard template.
- The operator replaces the template values in `state/accounts/<account>/wireguard.conf`.
- `./rbs up <account>` validates the account and starts/builds the Compose project.
- `./rbs down <account>`, `logs`, `status`, `ip`, and `connect` cover routine operations.
- `./rbs doctor` validates host dependencies.

`up` refuses obvious placeholder WireGuard configurations before Docker is invoked.

## Debian bootstrap

`scripts/bootstrap-debian.sh` installs the Docker Engine and Compose plugin from Docker's signed Debian repository on Debian 13. It does not install a desktop environment, Xorg, GNOME, KDE, or XFCE on the VM.

## Verification

CI performs three classes of checks:

1. Shell syntax and ShellCheck for repository scripts.
2. Static security invariants for Compose and browser launch configuration.
3. `docker compose config` rendering with synthetic non-secret account data.
4. Browser image build to catch package/repository breakage.

Runtime verification is provided by `./rbs ip <account>`, which queries a public IP endpoint from the shared VPN namespace. Operators should also test the failure case by stopping or invalidating the tunnel and confirming Internet access fails while the Xpra session remains reachable.

## Public repository safety

Only examples contain WireGuard-shaped values, clearly marked as placeholders. `.gitignore` excludes all runtime account state. CI rejects common WireGuard private-key assignments outside example/documentation paths.
