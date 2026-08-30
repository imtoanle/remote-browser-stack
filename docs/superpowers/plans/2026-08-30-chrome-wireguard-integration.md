# Chrome Stable and WireGuard Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Google Chrome Stable the default browser, provision native external WireGuard exit servers reproducibly, and prove Gluetun fails closed when the WireGuard tunnel is unavailable.

**Architecture:** Keep the existing browser/Xpra/Gluetun topology. Replace only the browser package/launcher, add a root-only idempotent WireGuard+nftables server installer, and add a trusted self-hosted integration test that creates an ephemeral WireGuard server/client path and verifies healthy egress followed by no fallback after the server tunnel is removed.

**Tech Stack:** Debian 13, Docker/Compose, Google Chrome Stable, Xpra, Gluetun, WireGuard, nftables, Bash, GitHub Actions self-hosted runners.

**Spec:** `docs/superpowers/specs/2026-08-30-chrome-wireguard-integration-design.md`

## Global Constraints

- Default browser is Google Chrome Stable from Google's official Debian repository.
- Browser remains non-root, `cap_drop: ALL`, `no-new-privileges:true`, no `SYS_ADMIN`, no privileged mode, and no `--no-sandbox`.
- Browser continues to share Gluetun's network namespace with `network_mode: service:vpn`.
- WireGuard server provisioning is native host configuration using `/etc/wireguard` and a dedicated `inet rbs_wg` nftables table.
- Generated private keys/client configs must never be committed.
- CI runs only on trusted self-hosted branches/PRs and keeps `cancel-in-progress: true`.
- Kill-switch verification must use a real ephemeral WireGuard tunnel and must assert no direct fallback after tunnel failure.

---

### Task 1: Switch the browser image to Google Chrome Stable

**Files:**
- Modify: `browser/Dockerfile`
- Modify: `browser/start-browser.sh`
- Modify: `tests/static.sh`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Produces executable browser command `google-chrome-stable`.
- Persistent profile remains `/home/browser/profile`.

- [ ] **Step 1: Add failing static/runtime assertions for Chrome Stable**

Update `tests/static.sh` to require `google-chrome-stable` and forbid the Debian `chromium` package/launcher. Update CI process detection to accept `chrome`/`google-chrome` processes rather than `chromium*`.

- [ ] **Step 2: Verify the new assertions fail against the current branch**

Run via CI/static checks; expected failure because `browser/Dockerfile` still installs `chromium` and the launcher still calls `chromium`.

- [ ] **Step 3: Install Chrome from Google's official apt repository**

In `browser/Dockerfile`, import `https://dl.google.com/linux/linux_signing_key.pub` into `/usr/share/keyrings/google-chrome.gpg`, configure an amd64-only signed source for `https://dl.google.com/linux/chrome/deb/ stable main`, and install `google-chrome-stable`.

- [ ] **Step 4: Change the launcher**

Use:

```bash
exec dbus-run-session -- google-chrome-stable \
  --user-data-dir="$HOME/profile" \
  --disable-setuid-sandbox \
  --no-first-run \
  --no-default-browser-check \
  "${START_URL:-about:blank}"
```

Do not add `--no-sandbox`.

- [ ] **Step 5: Run browser image build and Xpra/Chrome smoke test**

Expected: Chrome Stable process remains alive under the existing hardened container policy.

- [ ] **Step 6: Commit**

Commit message: `feat: use Google Chrome Stable`

### Task 2: Add native external WireGuard server provisioning

**Files:**
- Create: `scripts/install-wireguard-server.sh`
- Create: `tests/wireguard-server-static.sh`
- Modify: `tests/static.sh`
- Modify: `README.md`
- Modify: `.gitignore`

**Interfaces:**
- CLI flags: `--endpoint`, `--interface`, `--listen-port`, `--server-address`, `--client-name`, `--client-address`, `--output`, `--wan-interface`, `--dns`.
- Produces `/etc/wireguard/<interface>.conf` and a Gluetun-compatible client config.

- [ ] **Step 1: Write failing static tests**

Require root check, supported Debian/Ubuntu OS detection, `wireguard-tools`/`nftables` installation, `net.ipv4.ip_forward=1`, dedicated `inet rbs_wg` table, masquerade, `wg-quick@` enablement, generated client `AllowedIPs = 0.0.0.0/0`, and `PersistentKeepalive = 25`.

- [ ] **Step 2: Verify tests fail because the installer does not exist**

Run `bash tests/wireguard-server-static.sh`; expected failure on missing script.

- [ ] **Step 3: Implement argument parsing and validation**

Reject missing endpoint/client name/client address, invalid root execution, unsupported OS, missing default WAN route when `--wan-interface` is omitted, and unsafe interface/client names.

- [ ] **Step 4: Implement package/sysctl/key provisioning**

Install required packages, enable persistent IPv4 forwarding using `/etc/sysctl.d/99-rbs-wireguard.conf`, create `/etc/wireguard`, and generate server/client keys with mode 0600 only when absent.

- [ ] **Step 5: Implement idempotent server/peer configuration**

Write a deterministic server interface configuration and append/update a peer block marked with `# rbs-client:<name>` without duplicates.

- [ ] **Step 6: Implement isolated nftables policy**

Create `/etc/nftables.d/rbs-wireguard.nft` defining `table inet rbs_wg`, forward rules between WG and WAN, established/related return traffic, and masquerade for the WG subnet. Include it from `/etc/nftables.conf` only once and never flush unrelated tables.

- [ ] **Step 7: Enable services and emit client config**

Enable/restart `nftables` and `wg-quick@<interface>`, then write the client file with server public key, endpoint, `AllowedIPs = 0.0.0.0/0`, and keepalive 25.

- [ ] **Step 8: Run static tests and ShellCheck**

Expected: PASS.

- [ ] **Step 9: Commit**

Commit message: `feat: provision external WireGuard servers`

### Task 3: Add real Gluetun/WireGuard kill-switch integration test

**Files:**
- Create: `tests/integration/wireguard-killswitch.sh`
- Modify: `.github/workflows/ci.yml`
- Modify: `tests/static.sh`
- Modify: `README.md`

**Interfaces:**
- Test generates ephemeral server/client WireGuard keys and RFC1918 subnets.
- Test exits 0 only if healthy-tunnel connectivity succeeds and post-failure direct fallback is impossible.

- [ ] **Step 1: Add CI/static assertion requiring the integration test and job**

Require a `network-integration` job on `[self-hosted, linux]` with the same trusted-PR guard and prerequisite checks for Docker, `wg`, `ip`, `/dev/net/tun`.

- [ ] **Step 2: Verify static check fails before implementation**

Expected: missing integration script/job.

- [ ] **Step 3: Build an ephemeral WireGuard server container/network**

Use a privileged-enough disposable WireGuard server container with only `NET_ADMIN` and `/dev/net/tun`, generated keys, and a dedicated Docker network. Do not use production credentials.

- [ ] **Step 4: Start Gluetun with the generated client configuration**

Mount the generated `wg0.conf` read-only into Gluetun and wait until WireGuard is healthy/handshaking.

- [ ] **Step 5: Start a probe sharing Gluetun's namespace**

Use `network_mode: container:<gluetun-container>` or equivalent to ensure the probe has no independent Docker interface.

- [ ] **Step 6: Prove healthy tunnel traffic**

Run a request through the probe to a test endpoint reachable only through the server-side path and assert success.

- [ ] **Step 7: Destroy the server-side WireGuard path**

Stop/remove the server endpoint without stopping Gluetun/probe.

- [ ] **Step 8: Prove fail-closed behavior**

Assert repeated probe attempts fail and inspect the shared namespace to ensure there is no direct fallback route capable of bypassing Gluetun's firewall.

- [ ] **Step 9: Ensure cleanup always runs**

Trap removal of containers, networks, temporary files, and keys.

- [ ] **Step 10: Run the integration test on the self-hosted runner**

Expected: PASS for both healthy and failed tunnel phases.

- [ ] **Step 11: Commit**

Commit message: `test: verify WireGuard kill switch`

### Task 4: Final verification and documentation consistency

**Files:**
- Modify as needed: `README.md`, `docs/security.md`, spec/plan references

- [ ] **Step 1: Run ShellCheck/static/Compose rendering**

Expected: PASS.

- [ ] **Step 2: Run Chrome runtime smoke test**

Expected: PASS with Google Chrome Stable.

- [ ] **Step 3: Run WireGuard server static tests**

Expected: PASS.

- [ ] **Step 4: Run kill-switch integration test**

Expected: PASS.

- [ ] **Step 5: Inspect the PR diff for secret/private-key leaks and sandbox regressions**

Expected: no keys, no `--no-sandbox`, no privileged browser, no direct browser network.

- [ ] **Step 6: Update PR summary and leave PR unmerged**

Report exact CI run/commit evidence; do not mark complete until the latest head is green.
