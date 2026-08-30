# Initial Remote Browser Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reusable headless Debian remote-browser stack with one persistent Chromium identity and fail-closed WireGuard namespace per account.

**Architecture:** Each account is a separate Docker Compose project. Chromium + Xpra shares the Gluetun service network namespace, making Gluetun's WireGuard firewall the only browser egress path while the Xpra management port is published by the VPN service.

**Tech Stack:** Debian 13, Docker Engine + Compose v2, Chromium, Xpra 6 stable, Gluetun v3.41.1, WireGuard, Bash, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-30-initial-stack-design.md`

## Global Constraints

- Browser egress is fail-closed: `network_mode: service:vpn` is mandatory.
- Xpra binds to `127.0.0.1` by default.
- Browser runs unprivileged and Chromium sandboxing stays enabled.
- Runtime credentials and profile data are never committed.
- The Debian VM itself remains headless; GUI dependencies live inside the browser container.

---

### Task 1: Security contract tests

**Files:**
- Create: `tests/static.sh`
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: repository files.
- Produces: an executable test contract that fails until the stack files satisfy the design.

- [ ] **Step 1: Write the failing static test**

The test must require `compose.yaml`, `browser/Dockerfile`, `browser/entrypoint.sh`, `.gitignore`, `rbs`, and `config/wireguard.example.conf`; assert `network_mode: service:vpn`; reject host networking, privileged browser mode and `--no-sandbox`; and require loopback as the sample Xpra bind.

- [ ] **Step 2: Run it and verify RED**

Run: `bash tests/static.sh`

Expected: non-zero exit because the production stack files do not exist yet.

- [ ] **Step 3: Add CI around the contract**

CI runs ShellCheck, the static test, synthetic `docker compose config`, and a browser-image build.

- [ ] **Step 4: Commit**

Commit message: `test: define remote browser security contract`

### Task 2: Browser and VPN Compose stack

**Files:**
- Create: `compose.yaml`
- Create: `browser/Dockerfile`
- Create: `browser/entrypoint.sh`
- Create: `.env.account.example`
- Create: `config/wireguard.example.conf`
- Create: `.gitignore`

**Interfaces:**
- Consumes: `ACCOUNT_NAME`, `ACCOUNT_DIR`, `XPRA_BIND_IP`, `XPRA_PORT`, `START_URL`.
- Produces: Compose services `vpn` and `browser`, named volume `browser-profile`, Xpra TCP port 14500 inside the shared namespace.

- [ ] **Step 1: Render the failing Compose test against missing files**

Run: `bash tests/static.sh`

Expected: FAIL from required stack files.

- [ ] **Step 2: Add the minimal Compose topology**

Use `qmcgaw/gluetun:v3.41.1`, custom WireGuard mode, `NET_ADMIN`, `/dev/net/tun`, `FIREWALL_INPUT_PORTS=14500`, and `${XPRA_BIND_IP:-127.0.0.1}:${XPRA_PORT}:14500`. The browser service uses `network_mode: service:vpn`, no ports, `cap_drop: [ALL]`, `no-new-privileges`, and a named profile volume.

- [ ] **Step 3: Add the browser image**

Use Debian 13 slim. Install Chromium plus Xpra stable from the signed Trixie Xpra repository. Create UID/GID 1000 `browser`, copy the entrypoint, and run as that user.

- [ ] **Step 4: Add Xpra launch**

Start `xpra seamless :100` on `0.0.0.0:14500` with `auth=file(filename=/run/secrets/xpra_password)`, disable unneeded printer/webcam/pulseaudio/mdns features, and start Chromium with `/home/browser/profile` without `--no-sandbox`.

- [ ] **Step 5: Verify GREEN for static and Compose tests**

Run: `bash tests/static.sh`

Run: `docker compose --env-file .env.account.example config`

Expected: both succeed after synthetic secret/config files are prepared by CI.

- [ ] **Step 6: Commit**

Commit message: `feat: add isolated browser and WireGuard stack`

### Task 3: Account lifecycle CLI

**Files:**
- Create: `rbs`

**Interfaces:**
- Consumes: account names matching `[a-z0-9][a-z0-9-]{0,30}` and state under `state/accounts`.
- Produces: account runtime files and Docker Compose commands.

- [ ] **Step 1: Extend static tests for CLI requirements**

Require `create`, `up`, `down`, `logs`, `status`, `ip`, `connect`, and `doctor` command cases, and require placeholder rejection before `up`.

- [ ] **Step 2: Implement account creation**

Create mode-0700 state directories, copy the WireGuard example, generate a 48-hex-character Xpra password with `openssl rand -hex 24`, and choose the first available port in 14500-14599 not already assigned in repository state or listening on the host.

- [ ] **Step 3: Implement lifecycle commands**

Wrap Compose using project name `rbs-<account>` and the account's env file. `up` validates WireGuard placeholders; `ip` runs `wget` from the VPN container; `connect` prints SSH-tunnel and Xpra attach instructions without printing the password.

- [ ] **Step 4: Verify shell and static checks**

Run: `bash -n rbs && shellcheck rbs && bash tests/static.sh`

Expected: PASS.

- [ ] **Step 5: Commit**

Commit message: `feat: add account lifecycle CLI`

### Task 4: Debian bootstrap and operator documentation

**Files:**
- Create: `scripts/bootstrap-debian.sh`
- Modify: `README.md`
- Create: `docs/security.md`
- Create: `LICENSE`

**Interfaces:**
- Consumes: fresh Debian 13 VM with root/sudo access.
- Produces: Docker Engine + Compose plugin and documented deployment/security workflow.

- [ ] **Step 1: Add bootstrap validation to static tests**

Require Debian/Trixie checks, Docker's signed apt keyring, Compose plugin installation, and no desktop packages.

- [ ] **Step 2: Implement bootstrap script**

Install Docker's official signed repository and packages `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, and `docker-compose-plugin`. Enable Docker. Do not silently add users to the root-equivalent `docker` group.

- [ ] **Step 3: Write public documentation**

Document Proxmox VM expectations, quick start, Xpra SSH tunnel access, per-account workflow, kill-switch semantics, leak testing, upgrades, and threat-model limitations.

- [ ] **Step 4: Verify all repository checks**

Run: `bash tests/static.sh`

Run: `shellcheck rbs scripts/bootstrap-debian.sh browser/entrypoint.sh tests/static.sh`

Run: synthetic `docker compose config`.

Run: `docker build browser`.

Expected: all commands succeed.

- [ ] **Step 5: Commit**

Commit message: `docs: add bootstrap and operating guide`
