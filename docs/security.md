# Security model

Remote Browser Stack is designed around a narrow guarantee: **browser traffic must not silently fall back to the Debian VM's ordinary Internet route when the account WireGuard tunnel is unavailable.**

## Trust boundaries

Trusted:

- the Debian/Proxmox administrator;
- Docker Engine on the VM;
- the chosen WireGuard endpoint/provider;
- the client workstation used to attach to Xpra.

Not assumed trustworthy:

- websites loaded in Google Chrome;
- the normal WAN path of the Debian VM as a browser egress path;
- other browser identities running on the same VM.

A root compromise of the VM or Docker daemon is outside this isolation boundary. Docker administrators can inspect containers, volumes, and runtime secrets.

## Why the browser cannot use the normal Docker route

The browser service is configured with:

```yaml
network_mode: "service:vpn"
```

Docker therefore places it in the VPN service's network namespace instead of attaching it to its own bridge network. The browser cannot choose a separate Docker `eth0` because it does not own one.

Gluetun owns the namespace, WireGuard interface, DNS, routes, and fail-closed firewall. Its non-VPN route is required to reach the configured WireGuard endpoint, but normal browser egress is constrained by Gluetun's firewall. If the tunnel disappears, that firewall remains active.

CI verifies the failure path with a disposable real WireGuard tunnel: healthy egress must work through the tunnel, then repeated Internet requests must fail after the server endpoint is stopped.

## Xpra management traffic

Because browser and VPN share a namespace, Xpra's TCP listener also exists inside the Gluetun namespace. `FIREWALL_INPUT_PORTS=14500` explicitly allows that listener, and the Docker port mapping belongs to the VPN service.

The host-side mapping defaults to:

```text
127.0.0.1:<account-port> -> namespace:14500
```

This keeps management reachable without giving Chrome an independent network path. The preferred remote transport is an SSH local-forward. If direct LAN binding is configured, use only a trusted management network.

## Browser sandbox

Google Chrome Stable runs as a non-root user. The browser container drops all Docker capabilities and enables `no-new-privileges`.

Chrome is launched with `--disable-setuid-sandbox`. This disables the legacy SUID helper, not Chrome's sandbox as a whole: Chrome uses its unprivileged user-namespace sandbox plus its inner seccomp-BPF sandbox.

The project deliberately forbids `--no-sandbox`, privileged browser containers, `SYS_ADMIN`, and `seccomp=unconfined` in production runtime paths.

Docker's generated `docker-default` AppArmor profile is disabled only for the browser container because it blocks the user-namespace sandbox on the tested host. The browser still runs non-root with all outer capabilities dropped, NNP enabled, a Moby-derived seccomp profile, and Chrome's own sandbox. The VPN container keeps Docker's normal AppArmor confinement.

The custom seccomp profile starts from a pinned modern Moby profile and additionally permits only the namespace/filesystem syscalls proven necessary for Chrome's inner sandbox (`clone`, `setns`, `unshare`, and `chroot`). CI starts Chrome with the same production security posture so sandbox startup failures are caught rather than hidden by `--no-sandbox`.

Container isolation is not a replacement for a VM boundary against kernel/container escapes. The design therefore targets a dedicated Debian VM rather than mixing browser workloads directly with unrelated Proxmox host services.

## Persistent data

Every account has a separate Docker named volume containing its Chrome profile. Treat it as sensitive: it can contain cookies, sessions, saved credentials, local storage, IndexedDB, browsing history, and extensions.

The Xpra password and real WireGuard client configuration live under `state/accounts/<name>/`, which is ignored by Git and created with restrictive permissions. Backups of either account state or browser profiles should be encrypted.

## WireGuard peers and shared exits

The recommended v1 model is one Gluetun/WireGuard peer per browser account. Multiple peers can terminate on the same external WireGuard server and therefore share the same public exit IP while remaining separate tunnel states.

Do not copy the exact same WireGuard private key/config into multiple simultaneously running Gluetun containers. WireGuard identifies a peer by public key and updates that peer's endpoint as authenticated packets arrive; two independent clients using the same key can cause endpoint roaming/flapping.

A single Gluetun namespace can technically be shared by multiple browser containers, but that makes those browsers share routes, firewall state, DNS state, and tunnel failure domain. The current v1 Compose topology intentionally does not implement that mode.

## IPv6 and DNS

The current self-hosted WireGuard server installer is IPv4-only. The generated server-side client configuration uses `AllowedIPs = 0.0.0.0/0`.

If an external VPN provider supplies IPv6, verify the deployment explicitly before relying on it. Do not leave a non-VPN IPv6 default route available to the browser namespace.

DNS-over-HTTPS performed by Chrome is not a routing bypass: it is still IP traffic from the shared namespace and remains subject to the VPN firewall.

## Verification checklist

Before using a new identity:

1. `./rbs status <account>` shows the services running and VPN healthy.
2. `./rbs ip <account>` returns the expected VPN exit address rather than the VM WAN address.
3. In Chrome, verify IP/DNS/WebRTC behavior with a reputable leak-test site.
4. Break the VPN connection intentionally.
5. Confirm existing and new browser requests fail instead of using the VM WAN IP.
6. Confirm Xpra remains accessible through the intended management path.
7. Restore WireGuard and confirm connectivity returns through the expected exit.

Repeat the failure test after meaningful changes to Docker, Gluetun, WireGuard configuration, kernel security policy, or Compose networking.

## CI security invariants

CI checks include:

- shell syntax and ShellCheck;
- static security contracts;
- synthetic Compose rendering;
- Google Chrome Stable + Xpra runtime smoke testing under the production sandbox policy;
- a real ephemeral WireGuard/Gluetun integration test that verifies fail-closed behavior;
- guards against host networking, privileged browser containers, `SYS_ADMIN`, `--no-sandbox`, `seccomp=unconfined`, non-loopback sample management binding, and committed WireGuard-looking private keys.

The integration test is intentionally run only on trusted self-hosted branches/PRs from the same repository; public fork PR code is not executed automatically on the persistent runner.
