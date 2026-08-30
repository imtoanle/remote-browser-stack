# Security model

Remote Browser Stack is designed around a narrow guarantee: **browser traffic must not silently fall back to the Debian VM's ordinary Internet route when the account WireGuard tunnel is unavailable.**

## Trust boundaries

Trusted:

- the Debian/Proxmox administrator;
- Docker Engine on the VM;
- the chosen WireGuard endpoint/provider;
- the client workstation used to attach to Xpra.

Not assumed trustworthy:

- websites loaded in Chromium;
- the normal WAN path of the Debian VM as a browser egress path;
- other browser identities running on the same VM.

A root compromise of the VM or Docker daemon is outside this isolation boundary. Docker administrators can inspect containers, volumes, and runtime secrets.

## Why the browser cannot use the normal Docker route

The browser service is configured with:

```yaml
network_mode: "service:vpn"
```

Docker therefore places it in the VPN service's network namespace instead of attaching it to its own bridge network. The browser cannot choose a separate Docker `eth0` because it does not own one.

Gluetun owns the namespace, sets up WireGuard, DNS, routing, and firewall policy. Its firewall only permits the traffic needed to reach the VPN endpoint on the non-VPN route and normal outbound traffic through the VPN interface. If the tunnel disappears, the firewall remains active.

## Xpra management traffic

Because browser and VPN share a namespace, Xpra's TCP listener also exists inside the Gluetun namespace. `FIREWALL_INPUT_PORTS=14500` explicitly allows that listener, and the Docker port mapping belongs to the VPN service.

The host-side mapping defaults to:

```text
127.0.0.1:<account-port> -> namespace:14500
```

This means Xpra remains useful for diagnosis without giving Chromium a bypass route.

The preferred remote transport is an SSH local-forward. If direct LAN binding is configured, use only a trusted management network. Do not expose the Xpra TCP listener directly to the public Internet.

## Browser sandbox

Chromium runs as a non-root user and the container drops all Linux capabilities. Debian's `chromium-sandbox` package is installed explicitly, and the project intentionally does not pass `--no-sandbox`.

The browser service intentionally does **not** use Docker's `no-new-privileges` option. Debian Chromium's setuid sandbox helper must temporarily execute with its root-owned SUID privilege to create the browser sandbox namespaces and then drops privileges again. `no-new-privileges` disables that transition and Chromium aborts rather than running without a usable sandbox.

This exception is limited to the browser's own sandbox bootstrap. The container remains non-root, unprivileged, with all Docker capabilities dropped. CI smoke-tests Chromium under that exact policy so changes that break sandbox startup are detected.

Container isolation is still not a replacement for a VM boundary against kernel/container escapes. The design uses a dedicated Debian VM so a browser compromise is also separated from unrelated Proxmox workloads.

## Persistent data

Every account has a separate Docker named volume containing its Chromium profile. Treat the volume as sensitive: it can contain cookies, sessions, saved credentials, local storage, IndexedDB, browsing history, and extensions.

The Xpra password and real WireGuard configuration live under `state/accounts/<name>/`, which is ignored by Git and created with restrictive file permissions.

Backups of either the account state or browser profile should be encrypted.

## IPv6 and DNS

The example WireGuard configuration includes both IPv4 and IPv6 default routes. Docker bridge IPv6 is not enabled by this project. Gluetun owns DNS handling in the shared namespace.

If the selected WireGuard service does not support IPv6, verify the deployment with an IPv6 leak test and keep IPv6 disabled on the relevant Docker/VM path rather than allowing a non-VPN IPv6 default route.

DNS-over-HTTPS performed by Chromium is not a routing bypass: it is still IP traffic from the shared namespace and remains subject to the VPN firewall.

## Verification checklist

Before using a new identity:

1. `./rbs status <account>` shows both services running and the VPN healthy.
2. `./rbs ip <account>` returns the expected VPN exit address, not the VM's WAN address.
3. In Chromium, verify IP/DNS/WebRTC behavior with a reputable leak-test site.
4. Break the VPN connection intentionally.
5. Confirm existing and new browser requests fail rather than using the VM's WAN IP.
6. Confirm Xpra remains accessible through the management path.
7. Restore WireGuard and confirm browser connectivity returns through the expected exit address.

Repeat the failure test after meaningful changes to Docker, Gluetun, WireGuard config, or Compose networking.

## CI security invariants

`tests/static.sh` prevents common accidental regressions, including:

- removing `network_mode: service:vpn`;
- adding host networking;
- enabling privileged containers;
- launching Chromium with `--no-sandbox`;
- omitting Debian's `chromium-sandbox` package;
- adding `no-new-privileges`, which prevents the Debian setuid sandbox helper from functioning;
- changing the example Xpra bind away from loopback;
- tracking runtime state;
- committing a WireGuard-looking private key outside explicitly allowed documentation/example files.

CI also starts Xpra and Chromium using the production browser capability policy. Static and startup checks do not replace the runtime VPN failure test on the target Debian VM.
