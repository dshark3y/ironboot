# ironboot

Most people spin up a fresh VPS, log in as root, and start deploying things. Port 22 open to the world. Password authentication on. No firewall. Default kernel settings. The server does whatever it needs to do until something goes wrong — and then they spend a weekend figuring out why 1,200 login attempts per hour are showing up in their logs.

This script fixes that. One run, 11 steps, guided prompts. Atomic output: a properly hardened Ubuntu or Debian server with auditable logs of every change made.

It is designed for developers setting up a fresh VPS who want a secure baseline without having to research every hardening decision from scratch. We built it because that research takes 4–6 hours the first time, and about 2 hours every subsequent time you forget what you did last time.

---

## Contents

- [Who this is for](#who-this-is-for)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [What the script does](#what-the-script-does)
  - [Step 1 — Admin user setup](#step-1--admin-user-setup)
  - [Step 2 — SSH hardening](#step-2--ssh-hardening)
  - [Step 3 — Kernel network hardening](#step-3--kernel-network-hardening)
  - [Step 4 — UFW firewall](#step-4--ufw-firewall)
  - [Step 5 — Fail2ban](#step-5--fail2ban)
  - [Step 6 — Git and GitHub access](#step-6--git-and-github-access)
  - [Step 7 — Tailscale](#step-7--tailscale)
  - [Step 8 — Optional public SSH closure](#step-8--optional-public-ssh-closure)
  - [Step 9 — Docker](#step-9--docker)
  - [Step 10 — Automatic security updates](#step-10--automatic-security-updates)
  - [Step 11 — Verification](#step-11--verification)
- [CLI reference](#cli-reference)
- [Step names for --only and --skip](#step-names-for---only-and---skip)
- [Common workflows](#common-workflows)
- [Post-run checks](#post-run-checks)
- [Logging](#logging)
- [Security notes](#security-notes)
- [Project structure](#project-structure)
- [Roadmap](#roadmap)
- [License](#license)

---

## Who this is for

Developers and small teams setting up a fresh VPS. The kind of setup where you want a repeatable, documented baseline — not a 300-line Ansible playbook or a managed security product.

Good fit:
- Fresh Hetzner, DigitalOcean, Vultr, or similar VPS
- Personal production servers running apps, APIs, or Docker workloads
- Team servers where you want everyone starting from the same baseline
- Anyone who has been locked out of a server after a bad SSH config change (more common than anyone admits)

Not the right tool for:
- Existing production servers with custom configurations — review each step carefully before running on anything non-fresh
- Non-systemd environments
- Non-Debian distributions (Ubuntu and Debian only)

---

## Requirements

- Ubuntu or Debian — fresh install strongly preferred
- Root access or `sudo`
- systemd
- Internet access for package installs

Optional, depending on which steps you enable:
- A [Tailscale](https://tailscale.com) account for private network access
- A GitHub account if you want deploy key access

---

## Quick start

**1. Copy the script to your server**

```bash
scp vps-bootstrap-v1.4.1.sh root@YOUR_SERVER_IP:~
```

Or download it directly on the server:

```bash
curl -O https://raw.githubusercontent.com/dshark3y/ironboot/main/vps-bootstrap-v1.4.1.sh
```

**2. Run it as root**

```bash
sudo bash vps-bootstrap-v1.4.1.sh
```

**3. Follow the prompts**

Each step explains what it will do before asking. Skip anything that does not apply. Riskier steps — SSH changes, firewall changes, closing public SSH — have extra warnings and safer defaults.

> **Before you run anything:** preview with `--dry-run` first, and keep your current SSH session open until you have confirmed the new access path works in a second terminal.

---

## What the script does

11 steps in sequence. Every step is optional — skip any with `--skip`, or run a single one with `--only`. Saying no to a step leaves the server in a clean, unbroken state. Nothing is irreversible without a warning.

---

### Step 1 — Admin user setup

**What it does**

Creates a non-root user, adds them to the `sudo` group, creates their `~/.ssh` directory with correct permissions (`700`), and optionally copies root's `authorized_keys` so they can log in immediately with the same SSH key.

**Why**

Running day-to-day tasks as root means a single typo in the wrong place has no recovery path. A dedicated admin user with `sudo` forces you to consciously escalate privilege — smaller blast radius, cleaner audit trail. Most VPS providers give you root by default. The first thing to do is step off it.

**Why copying `authorized_keys` makes sense**

If you already have SSH key access as root, copying those keys to the new user means you can log in as them immediately — without manually re-configuring SSH keys. That access is what lets you disable root SSH login in Step 2 without locking yourself out.

**What to watch for**

When prompted for a password, Linux will not echo characters as you type. This is expected. Type the password, press Enter, type it again.

---

### Step 2 — SSH hardening

**What it does**

Adjusts `/etc/ssh/sshd_config` to harden SSH access. Before restarting SSH, the script runs `sshd -t` to validate the config — a syntax error will not cut off your session.

You are asked about three things:
- **Changing the SSH port** — moves SSH off port 22
- **Disabling direct root login** — prevents SSH login as root
- **Disabling password authentication** — requires SSH keys

These are applied silently regardless of what you answer above (they are unambiguous hardening defaults):

| Setting | Value | Why |
|---|---|---|
| `MaxAuthTries` | `3` | Limits brute-force attempts per connection |
| `LoginGraceTime` | `30` | Disconnects unauthenticated connections after 30 seconds |
| `MaxSessions` | `3` | Caps concurrent sessions per connection |
| `X11Forwarding` | `no` | Disables X11 forwarding — a common attack surface on servers |
| `PermitEmptyPasswords` | `no` | Prevents login with blank passwords |
| `ClientAliveInterval` | `300` | Sends a keepalive every 5 minutes |
| `ClientAliveCountMax` | `3` | Disconnects after 3 missed keepalives (~15 minutes idle) |
| `PubkeyAuthentication` | `yes` | Explicitly enables SSH key authentication |

**Why change the SSH port**

Port 22 is scanned by automated bots constantly. Moving SSH to a non-standard port does not make it more secure against a targeted attack. It eliminates the background noise — thousands of connection attempts per day that clutter logs and keep fail2ban busy. Port `2293` is the suggested default. Any port above `1024` that is not otherwise in use works.

**Why disable root login**

Root is the highest-value target on any Linux server. Disabling SSH login for root means a compromised key cannot hand over the entire machine immediately. Everything goes through a named user, which is auditable and revocable.

**Why disable password authentication**

SSH passwords can be brute-forced. SSH keys cannot — they use asymmetric cryptography. Once key-based login is confirmed and working, keeping password auth enabled is unnecessary risk.

> **Safety check built in:** before offering to disable password auth, the script checks whether the target user has an `authorized_keys` file. If there are no SSH keys present, it blocks the option and explains why. This prevents the most common lockout scenario.

**What to watch for**

Never close your current session after making SSH changes. Open a second terminal, confirm the new login works, then close the original.

---

### Step 3 — Kernel network hardening

**What it does**

Writes `/etc/sysctl.d/99-vps-bootstrap.conf` and applies it with `sysctl --system`. Configures kernel-level network security parameters that most cloud images ship with at their defaults — which are not sensible for a public-facing server.

| Parameter | What it does |
|---|---|
| `net.ipv4.tcp_syncookies = 1` | SYN cookies — protects against SYN flood attacks |
| `accept_redirects = 0` | Blocks ICMP redirect acceptance — prevents routing table manipulation |
| `send_redirects = 0` | Stops the server from sending ICMP redirects |
| `accept_source_route = 0` | Rejects source-routed packets — a known attack vector |
| `log_martians = 1` | Logs packets with impossible source addresses |
| `icmp_echo_ignore_broadcasts = 1` | Prevents use in ICMP broadcast amplification attacks |
| `icmp_ignore_bogus_error_responses = 1` | Silences responses to malformed ICMP error packets |
| `rp_filter = 1` | Reverse path filtering — drops packets arriving on unexpected interfaces |

**Why**

Application-layer defences mean nothing if the kernel is behaving unsafely at the network level. A server can be perfectly configured at every other layer and still be vulnerable to IP spoofing, routing attacks, or used as a DDoS amplification node if these parameters are left at defaults. None of these settings break normal operation — they only restrict abnormal traffic patterns.

---

### Step 4 — UFW firewall

**What it does**

Installs and enables UFW (Uncomplicated Firewall) with a default-deny incoming policy. SSH is allowed on the active port before UFW is enabled — the ordering is intentional and not something you need to manage manually.

You are asked about:
- Temporarily allowing port 22 alongside a custom SSH port (useful during testing)
- Allowing HTTP (port 80)
- Allowing HTTPS (port 443)
- Rate limiting on the SSH port

**Why default-deny**

Without a firewall, every port your server is listening on is reachable from the public internet. Applications bind to ports — not all of them are intended to be public. Databases, internal APIs, and debug interfaces frequently listen on ports that should never be externally accessible. Default-deny means only ports you explicitly open are reachable, regardless of what runs on the server later.

**Why rate limit SSH**

`ufw limit` blocks a source IP after 6 or more connection attempts within 30 seconds. It is a lightweight first line of defence before fail2ban's threshold is reached. The two work together — rate limiting catches the burst; fail2ban catches the sustained attempt.

**Why SSH is allowed before UFW enables**

If you enable UFW with a default-deny policy before allowing your SSH port, you are locked out immediately. The script handles this ordering automatically.

---

### Step 5 — Fail2ban

**What it does**

Installs fail2ban and writes a jail for SSH to `/etc/fail2ban/jail.d/sshd-local.conf`. When a source IP fails authentication 3 times within 10 minutes, it is banned for 3 hours via UFW rules.

| Setting | Value | Why |
|---|---|---|
| `maxretry` | `3` | Bans after 3 failures — tighter than the default 5 |
| `bantime` | `3h` | Long enough to deter automated tools without being permanent |
| `findtime` | `10m` | Counts failures within a 10-minute window |
| `banaction` | `ufw` | UFW enforces bans — consistent with your firewall rules, visible in `ufw status` |

**Why fail2ban matters even with SSH keys**

Fail2ban is not only for password brute-force protection. It also blocks bots probing for valid usernames, testing for known vulnerabilities, and generating auth log noise. Even with password auth disabled, it keeps scan traffic down and logs readable.

**Why 3 retries**

A legitimate user failing SSH key auth more than 3 times has a configuration problem that more attempts will not fix. Three retries is enough for human error. Anything beyond that is a probe.

---

### Step 6 — Git and GitHub access

**What it does**

Installs `git` and `openssh-client`. Optionally generates an ed25519 SSH keypair for the admin user, adds GitHub to `known_hosts`, and prints the public key so you can add it to GitHub immediately.

**Why ed25519**

Ed25519 keys are shorter, faster, and considered more secure than RSA-2048 or RSA-4096 for modern use. They are supported by all current versions of GitHub, GitLab, and Bitbucket.

**Why a dedicated deploy key**

A server with its own SSH key for GitHub means you can revoke server access independently, see exactly which server is making GitHub requests in your audit log, and avoid exposing a personal key if the server is compromised.

**Why `ssh-keyscan` for `known_hosts`**

First-time SSH connections to GitHub prompt for host key confirmation — which blocks automated clones and deploys. `ssh-keyscan` pre-populates `known_hosts` so the connection works without manual intervention. This is a convenience trade-off; pinned keys are stricter for high-security environments.

---

### Step 7 — Tailscale

**What it does**

Installs Tailscale, enables and starts `tailscaled`, and optionally brings up the connection with SSH enabled. An auth key can be provided to authenticate non-interactively, or the script will print a login URL.

**What Tailscale is**

A zero-config VPN that creates a private network between your devices. Each machine on your Tailnet has a stable private IP and hostname regardless of its public IP. Traffic is encrypted end-to-end using WireGuard.

**Why Tailscale SSH**

Tailscale SSH routes SSH connections through your Tailnet instead of the public internet. The server's SSH port does not need to be open in UFW at all. Access is controlled by your identity provider, visible in the Tailscale admin panel, and revocable instantly. SSH keys are not required — Tailscale handles authentication.

**Why it defaults to no**

Tailscale requires an account and runs a persistent background service. It is the right call for personal infrastructure. It is not appropriate for every setup, and enabling it without understanding the implications can leave a server in an unexpected state.

---

### Step 8 — Optional public SSH closure

**What it does**

If Tailscale SSH was enabled in Step 7, this step offers to remove the UFW rules that allow public SSH access — leaving SSH reachable only through your Tailnet.

**Why this is ordered last**

The step only appears when Tailscale SSH is enabled in the same run. It defaults to no. The warnings are explicit: test Tailscale SSH from a separate terminal before answering yes. This ordering exists because removing public SSH access before confirming an alternative works is one of the most reliable ways to permanently lock yourself out of a server.

**When to say yes**

Only after:
1. Tailscale is connected and the server appears in your Tailscale dashboard
2. You have opened a second terminal and confirmed `tailscale ssh user@hostname` works
3. You are comfortable that Tailscale is the only access path going forward

---

### Step 9 — Docker

**What it does**

Installs Docker Engine and the Docker Compose plugin from Docker's official apt repository — not the version in Ubuntu or Debian's default repositories, which is typically several major versions behind. Enables the Docker service, and adds the admin user to the `docker` group.

Packages installed: `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`.

**Why Docker's own repository**

The Ubuntu and Debian package repositories ship a version of Docker that lags behind by months to years. Using Docker's own repository means current releases with up-to-date security patches. The script adds Docker's GPG key and signs the repository source before installing anything.

**Why add the user to the `docker` group**

Docker requires root by default. Adding the admin user to the `docker` group lets them run `docker` commands without `sudo`. This is effectively equivalent to root access — containers can mount the host filesystem. On a personal or small-team server where the admin is trusted, this is the standard trade-off.

---

### Step 10 — Automatic security updates

**What it does**

Installs `unattended-upgrades` and configures it to apply security updates daily. Auto-reboot is explicitly disabled.

| Setting | Value |
|---|---|
| Update package lists | Daily |
| Download upgradeable packages | Daily |
| Apply unattended upgrades | Daily |
| Auto-clean interval | Every 7 days |
| Auto-reboot | **Disabled** |

**Why automatic security updates**

The most common path to a compromised server is a known vulnerability in installed software that was never patched. Security updates for Ubuntu and Debian are released quickly when vulnerabilities are disclosed. Manually tracking and applying updates on a personal server is discipline that degrades over time. Unattended upgrades keeps the security baseline maintained without requiring it.

**Why auto-reboot is off**

Kernel updates that require a reboot are infrequent. Unexpected reboots disrupt running services. You want to control when the server restarts. Check whether a reboot is pending at any time:

```bash
cat /run/reboot-required 2>/dev/null && echo "reboot needed" || echo "no reboot needed"
```

---

### Step 11 — Verification

**What it does**

Runs a set of checks after the bootstrap to confirm the key services are in a working state:

- `sshd -t` — validates SSH config syntax
- `ufw status` — shows active firewall rules
- `fail2ban-client status` — confirms fail2ban is running
- `systemctl is-active docker` — checks the Docker service
- `tailscale status` — retrieves Tailscale connection state if installed

**Why**

A change in one step can have unintended effects that only surface when you try to use the server. Running automated checks immediately after setup catches the most common issues before you close the terminal. The results appear in the log file for future reference.

This step does not replace manual testing. Open a new terminal and verify your own access path before closing the original session.

---

## CLI reference

```
Usage: sudo bash vps-bootstrap-v1.4.1.sh [options]

Options:
  --dry-run          Show what would happen without making any changes
  --verbose          Stream command output to the terminal as well as the log
  --only=a,b,c       Run only the specified steps (comma-separated)
  --skip=a,b,c       Skip the specified steps (comma-separated)
  -h, --help         Show this help
```

### `--dry-run`

Preview every action without changing anything on the server. Prompts still appear; all writes, installs, and service restarts are shown as `(dry-run)`. Run this first on any server that is not a clean install.

```bash
sudo bash vps-bootstrap-v1.4.1.sh --dry-run
```

### `--verbose`

Stream command output live to the terminal instead of writing only to the log file. Useful for watching a failing step in real time.

```bash
sudo bash vps-bootstrap-v1.4.1.sh --verbose
```

### `--only`

Run specific steps and skip everything else. Useful for re-running a single step on an already-configured server.

```bash
sudo bash vps-bootstrap-v1.4.1.sh --only=docker,verify
```

### `--skip`

Run everything except the steps you name. Useful when most of the script applies but one or two steps do not.

```bash
sudo bash vps-bootstrap-v1.4.1.sh --skip=git,tailscale,close-ssh
```

---

## Step names for `--only` and `--skip`

| Name | Step |
|---|---|
| `user` | Admin user setup |
| `ssh` | SSH hardening |
| `sysctl` | Kernel network hardening |
| `ufw` | UFW firewall |
| `fail2ban` | Fail2ban brute-force protection |
| `git` | Git and GitHub deploy key |
| `tailscale` | Tailscale installation |
| `close-ssh` | Remove public SSH firewall access |
| `docker` | Docker Engine and Compose |
| `auto-updates` | Unattended security upgrades |
| `verify` | Final verification checks |

---

## Common workflows

### Fresh VPS — public SSH retained

Admin user, hardened SSH, firewall, fail2ban, Docker, auto-updates. SSH stays reachable from the public internet on a custom port.

```bash
sudo bash vps-bootstrap-v1.4.1.sh
```

Suggested answers:
- Create admin user: **yes**
- Copy root SSH keys to new user: **yes**
- Change SSH port: **yes** — pick a port above 1024
- Disable root login: **yes** — after confirming the new user has SSH key access
- Disable password auth: **yes** — if key-based login is confirmed working
- Enable UFW: **yes** — allow 80/443 if running a web server
- Install fail2ban: **yes**
- Install Tailscale: **no**
- Install Docker: **yes**
- Auto security updates: **yes**

---

### Tailscale-first VPS — no public SSH

For a setup where SSH is never exposed to the public internet. After this, the server is only reachable through your Tailnet.

```bash
sudo bash vps-bootstrap-v1.4.1.sh
```

Suggested answers:
- Create admin user: **yes**
- Copy root SSH keys: **yes**
- Disable root login: **yes**
- Enable UFW: **yes**
- Install fail2ban: **yes**
- Install Tailscale: **yes**
- Enable Tailscale SSH: **yes**
- **Open a second terminal. Run `tailscale ssh user@hostname`. Confirm it works.**
- Remove public SSH access: **yes** — only after the test above passes

---

### Re-run a single step

The script is safe to run multiple times. Adding Docker to an already-hardened server:

```bash
sudo bash vps-bootstrap-v1.4.1.sh --only=docker,verify
```

Adding Tailscale later:

```bash
sudo bash vps-bootstrap-v1.4.1.sh --only=tailscale
```

---

## Post-run checks

Test every access path in a new terminal before closing your original session.

**SSH as the new admin user:**

```bash
ssh youruser@YOUR_SERVER_IP -p YOUR_SSH_PORT
```

**Firewall rules:**

```bash
sudo ufw status verbose
```

**Fail2ban:**

```bash
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

**Docker:**

```bash
docker --version
docker compose version
sudo systemctl status docker
```

**Tailscale:**

```bash
tailscale status
tailscale ssh youruser@your-server-hostname
```

**Full audit log:**

```bash
sudo less /var/log/vps-bootstrap-YYYYmmdd-HHMMSS.log
```

---

## Logging

Every run writes a timestamped log to `/var/log/`:

```
/var/log/vps-bootstrap-20240315-143022.log
```

The path is printed at startup and in the final summary. The log records every command run with its full arguments, every file written with path/mode/owner, every service restart, and every timestamped action taken by the script.

Created with `chmod 600` — only root can read it.

---

## Security notes

**Never close your current session until the new one is tested.** This applies to every SSH change, every firewall change, and every decision to close public access. Keep the original session open, open a second terminal, confirm everything works, then close the original. There is no other safe order.

**The script validates SSH config before restarting.** `sshd -t` runs before any SSH service restart. If the config has a syntax error, the script stops and points you to the backup. Backups are written as `filename.bak.TIMESTAMP` before any changes are made.

**Password auth is blocked from being disabled if no SSH keys exist.** If the target user has no `authorized_keys` file, the option is not offered. The script tells you to add a key first, then re-run with `--only=ssh`.

**Run `--dry-run` on any non-fresh server.** The script is designed for clean installs. On an existing server, some steps may conflict with your current configuration. Preview before applying.

This script establishes a solid baseline. It does not replace monitoring, regular access reviews, or application-level security for what you deploy on top.

---

## Project structure

```
.
├── README.md
└── vps-bootstrap-v1.4.1.sh
```

Recommended additions:

```
.
├── README.md
├── LICENSE
├── CHANGELOG.md
├── vps-bootstrap-v1.4.1.sh
└── examples/
    ├── sample-output.txt
    └── tailscale-first-runbook.md
```

---

## Roadmap

- **Drop-in SSH config** — write hardening to `/etc/ssh/sshd_config.d/` instead of editing the main file directly
- **Pinned GitHub host keys** — replace `ssh-keyscan` with verified fingerprints
- **Swap file creation** — useful on low-memory VPS instances
- **Hostname and timezone setup** — common first-boot tasks currently done manually
- **Shellcheck CI** — automated linting before release
- **Caddy / reverse proxy step** — optional setup for servers running web applications
- **Rollback hints** — better guidance when a step fails mid-way

---

## License

MIT License. See `LICENSE` for details.
