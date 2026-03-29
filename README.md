# ironboot

I see many people setting up [OpenClaw](https://openclaw.ai), or hosting vibecoded projects and more. I've been working on servers for many years, hosting my own services, mainly on bare metal blank servers. I used to go through a process of step by step setup of these servers, meeting the bare minimum criteria for safe usage. Stuff like non-root user, closing ports, setting up Tailscale (highly recommend), installing fail2ban, turning off root. If you're not doing any of these things, it's an issue.

Thankfully now I've fixed all your problems. I'm opening up my own quick script that walks you through hardening a fresh Ubuntu or Debian VPS - guided prompts, 12 steps, one run. It covers creating a non-root admin user, locking down SSH, hardening the kernel, setting up a firewall, installing fail2ban, optional Tailscale setup, Docker, automatic security updates, and scheduled maintenance. It logs everything it does so you have a full audit trail of what changed and when.

No config files to write. No research rabbit holes. Just run it and answer the questions.

This script is primarily built for my own use and infrastructure - I'm sharing it because it might save someone else the same hours I've spent doing this manually. Use it as a starting point, review the steps for your own setup, and adapt as needed.

---

## My recommended stack

If you're starting from scratch, here's what I use and would point anyone towards:

**Host - [Hetzner](https://hetzner.com)**
Genuinely the best value in cloud hosting. A 2–4 core VPS handles OpenClaw, multiple web apps, or a handful of side projects without breaking a sweat. I run [sharkey.io](https://sharkey.io) and about a dozen other sites and projects on a single Hetzner box. The pricing is a fraction of AWS or DigitalOcean for equivalent specs.

**Network access - [Tailscale](https://tailscale.com)**
Set this up on every device you own and every server you run. Seriously. It creates a private encrypted network between all your machines - your laptop, your phone, your servers - and SSH becomes as simple as `tailscale ssh user@hostname` from anywhere. No exposed ports, no managing SSH keys across devices, no VPN config. I'd consider it non-negotiable at this point.

---

## Contents

- [My recommended stack](#my-recommended-stack)
- [Who this is for](#who-this-is-for)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [What the script does](#what-the-script-does)
  - [Step 1 - Admin user setup](#step-1--admin-user-setup)
  - [Step 2 - SSH hardening](#step-2--ssh-hardening)
  - [Step 3 - Kernel network hardening](#step-3--kernel-network-hardening)
  - [Step 4 - UFW firewall](#step-4--ufw-firewall)
  - [Step 5 - Fail2ban](#step-5--fail2ban)
  - [Step 6 - Git and GitHub access](#step-6--git-and-github-access)
  - [Step 7 - Tailscale](#step-7--tailscale)
  - [Step 8 - Optional public SSH closure](#step-8--optional-public-ssh-closure)
  - [Step 9 - Docker](#step-9--docker)
  - [Step 10 - Automatic security updates](#step-10--automatic-security-updates)
  - [Step 11 - Scheduled maintenance](#step-11--scheduled-maintenance)
  - [Step 12 - Verification](#step-12--verification)
- [CLI reference](#cli-reference)
- [Step names for --only and --skip](#step-names-for---only-and---skip)
- [Common workflows](#common-workflows)
- [Post-run checks](#post-run-checks)
- [Logging](#logging)
- [Security notes](#security-notes)
- [Project structure](#project-structure)
- [Roadmap](#roadmap)
- [License](#license)
- [Inspiration and prior work](#inspiration-and-prior-work)

---

## Who this is for

Anyone spinning up a fresh VPS who doesn't want to spend an afternoon researching what they should be doing - or worse, skipping it entirely because it's tedious.

Good fit:
- Fresh Hetzner, DigitalOcean, Vultr, or similar VPS
- Personal production servers running apps, APIs, or Docker workloads
- Team servers where you want everyone starting from the same hardened baseline
- Anyone who has been locked out of a server after a bad SSH config change (it happens to everyone once)

Not the right tool for:
- Existing production servers with custom configurations - run `--dry-run` and review every step before applying anything
- Non-systemd environments
- Non-Debian distributions (Ubuntu and Debian only)

---

## Requirements

- Ubuntu or Debian - fresh install strongly preferred
- Root access or `sudo`
- systemd
- Internet access for package installs

Optional depending on which steps you enable:
- A [Tailscale](https://tailscale.com) account - I'd strongly recommend this
- A GitHub account if you want deploy key access

---

## Quick start

**1. Copy the script to your server**

```bash
scp vps-bootstrap-v1.6.1.sh root@YOUR_SERVER_IP:~
```

Or download it directly on the server:

```bash
curl -O https://raw.githubusercontent.com/dshark3y/ironboot/main/vps-bootstrap-v1.6.1.sh
```

**2. Run it as root**

```bash
sudo bash vps-bootstrap-v1.6.1.sh
```

**3. Follow the prompts**

Each step tells you what it's going to do before it does it. You can skip anything that doesn't apply to your setup. The riskier steps - SSH changes, firewall changes, closing public SSH - have explicit warnings and conservative defaults. You won't be surprised.

> **Important:** always keep your current SSH session open while making SSH or firewall changes. Open a second terminal, confirm the new login works, then close the original. Don't skip this.

---

## What the script does

12 steps in sequence. Every step is optional - skip any with `--skip`, or target a specific one with `--only`. Saying no to a step leaves the server clean. Nothing is done irreversibly without a warning first.

---

### Step 1 - Admin user setup

**What it does**

Creates a non-root user, adds them to the `sudo` group, sets up their `~/.ssh` directory with correct permissions (`700`), and optionally copies root's `authorized_keys` across so they can log in straight away with the same SSH key you already have.

**Why**

Logging in as root for everything is a bad habit. One wrong command with no recovery path. A non-root user with `sudo` means you have to consciously escalate privilege - much smaller blast radius if something goes wrong. Most VPS providers give you root access by default. First thing to do is get off it.

**Why copying `authorized_keys` matters**

If you already have SSH key access as root, copying those keys to the new user means you can log in as them immediately without any additional SSH key setup. That working login is what lets you safely disable root SSH access in the next step without locking yourself out.

**What to watch for**

When prompted to set a password, Linux won't show anything as you type - this is normal. Type the password, hit Enter, type it again to confirm.

---

### Step 2 - SSH hardening

**What it does**

Tightens up `/etc/ssh/sshd_config`. Before restarting SSH, the script validates the config with `sshd -t` - a syntax error will not cut off your session.

You're asked about three things:
- **Changing the SSH port** - moves SSH off port 22
- **Disabling direct root login** - prevents SSH login as root
- **Disabling password authentication** - requires SSH keys

These are applied silently regardless of what you answer above - they're unambiguous hardening defaults with no real downside:

| Setting | Value | Why |
|---|---|---|
| `MaxAuthTries` | `3` | Limits brute-force attempts per connection |
| `LoginGraceTime` | `30` | Disconnects unauthenticated connections after 30 seconds |
| `MaxSessions` | `3` | Caps concurrent sessions per connection |
| `X11Forwarding` | `no` | Disables X11 forwarding - nobody needs this on a server |
| `PermitEmptyPasswords` | `no` | Prevents login with blank passwords |
| `ClientAliveInterval` | `300` | Sends a keepalive every 5 minutes |
| `ClientAliveCountMax` | `3` | Disconnects after 3 missed keepalives (~15 minutes idle) |
| `PubkeyAuthentication` | `yes` | Explicitly enables SSH key authentication |

**Why change the SSH port**

Port 22 gets scanned constantly by automated bots. Moving SSH somewhere else doesn't make it more secure against anyone actually targeting you, but it kills the background noise - thousands of connection attempts a day that clog your logs and keep fail2ban busy for no reason. Port `2293` is suggested as a default. Anything above `1024` that's not already in use works.

**Why disable root login**

Root is the most valuable account on any Linux server. Disabling SSH login for root means a compromised key can't immediately hand over the entire machine. All access goes through a named user, which is auditable and easier to revoke.

**Why disable password authentication**

SSH passwords can be brute-forced. SSH keys can't - they use asymmetric cryptography. Once you've confirmed key-based login works, keeping password auth enabled is unnecessary risk with no benefit.

> **Safety check:** before offering to disable password auth, the script checks whether the target user actually has an `authorized_keys` file. If there are no SSH keys present, it refuses to disable password auth and tells you to add a key first. This prevents the most common lockout scenario.

**What to watch for**

Open a second terminal and confirm the new login works before closing your current session. Every time.

---

### Step 3 - Kernel network hardening

**What it does**

Writes `/etc/sysctl.d/99-vps-bootstrap.conf` and applies it with `sysctl --system`. These are kernel-level network security settings that most cloud images ship with at defaults that aren't appropriate for a public-facing server.

| Parameter | What it does |
|---|---|
| `net.ipv4.tcp_syncookies = 1` | SYN flood protection |
| `accept_redirects = 0` | Blocks ICMP redirect acceptance - prevents routing table manipulation |
| `send_redirects = 0` | Stops the server from sending ICMP redirects |
| `accept_source_route = 0` | Rejects source-routed packets - a known attack vector |
| `log_martians = 1` | Logs packets with impossible source addresses |
| `icmp_echo_ignore_broadcasts = 1` | Prevents use in ICMP broadcast amplification attacks |
| `icmp_ignore_bogus_error_responses = 1` | Ignores responses to malformed ICMP error packets |
| `rp_filter = 1` | Reverse path filtering - drops packets arriving on unexpected interfaces |

**Why**

You can do everything right at the application layer and still be vulnerable at the network layer if these are left at defaults. None of these break normal server operation - they only affect abnormal traffic patterns. There's no reason not to apply them.

---

### Step 4 - UFW firewall

**What it does**

Installs and enables UFW (Uncomplicated Firewall) with a default-deny incoming policy. SSH gets allowed on the active port before UFW is enabled - this ordering is handled automatically so you can't accidentally lock yourself out by enabling the firewall before your own connection is whitelisted.

You're asked about:
- Temporarily allowing port 22 alongside a custom SSH port (useful while you're testing)
- Allowing HTTP (port 80)
- Allowing HTTPS (port 443)
- Rate limiting on the SSH port

**Why default-deny**

Without a firewall, every port your server is listening on is reachable from the internet. Applications bind to ports they need - not all of them are meant to be public. Databases, internal APIs, and debug interfaces frequently end up listening on ports that should never be externally accessible. Default-deny means only ports you explicitly open are reachable, regardless of what runs on the server later.

**Why rate limit SSH**

`ufw limit` blocks a source IP after 6 or more connection attempts within 30 seconds. It's a lightweight first line of defence that works alongside fail2ban - rate limiting catches the burst, fail2ban handles the sustained attempt.

---

### Step 5 - Fail2ban

**What it does**

Installs fail2ban and writes an SSH jail to `/etc/fail2ban/jail.d/sshd-local.conf`. After 3 failed authentication attempts within 10 minutes, the source IP is banned for 3 hours. Bans are enforced through UFW rules.

| Setting | Value | Why |
|---|---|---|
| `maxretry` | `3` | Bans after 3 failures - tighter than the default 5 |
| `bantime` | `3h` | Long enough to deter automated tools |
| `findtime` | `10m` | Counts failures within a 10-minute window |
| `banaction` | `ufw` | UFW enforces bans - consistent with your firewall, visible in `ufw status` |

**Why fail2ban even with SSH keys**

It's not just for brute-forcing passwords. It also blocks bots probing for valid usernames, testing for known vulnerabilities, and generating log noise. Even with password auth disabled, it keeps scans down and logs readable. I've been running it on every server I manage for years.

**Why 3 retries**

A legitimate user failing SSH key auth more than 3 times has a config problem that extra attempts won't fix. Three is enough for genuine mistakes and strict enough to stop automated tools fast.

---

### Step 6 - Git and GitHub access

**What it does**

Installs `git` and `openssh-client`. Optionally generates an ed25519 SSH keypair for the admin user, adds GitHub to `known_hosts`, and prints the public key so you can add it to GitHub straight away.

**Why ed25519**

Shorter, faster, and more secure than RSA-2048 or RSA-4096 for modern use. Supported everywhere - GitHub, GitLab, Bitbucket.

**Why a dedicated deploy key**

A server with its own GitHub key means you can revoke server access independently, see exactly which server is making GitHub requests, and avoid exposing your personal key if the server is ever compromised.

**Why `ssh-keyscan` for `known_hosts`**

First-time SSH connections to GitHub prompt for host key confirmation - which blocks automated clones and deploys. `ssh-keyscan` pre-populates `known_hosts` so connections work without manual intervention. Pinned keys are stricter for high-security environments, but this is fine for the vast majority of setups.

---

### Step 7 - Tailscale

**What it does**

Installs Tailscale, enables and starts `tailscaled`, and optionally brings up the connection with SSH enabled. Provide an auth key to authenticate non-interactively, or the script will give you a login URL to finish in a browser.

**What Tailscale is**

A zero-config VPN that creates a private network between your devices. Every machine on your Tailnet gets a stable private IP and hostname. Traffic is encrypted end-to-end over WireGuard. Once it's set up, accessing your server privately is as easy as `tailscale ssh user@hostname` from any device on your Tailnet.

**Why I strongly recommend Tailscale SSH**

With Tailscale SSH, your server's SSH port doesn't need to be open to the internet at all. SSH is only reachable from your own devices. Authentication is handled by your identity provider. Access is visible and revocable from the Tailscale admin panel instantly. I run this on everything I manage personally - it removes an entire attack surface.

**Why it defaults to no**

Tailscale requires an account and runs a persistent background service. It's not appropriate for every setup, and enabling it without understanding what it does can leave a server in a confusing state if you're not expecting it.

---

### Step 8 - Optional public SSH closure

**What it does**

If Tailscale SSH was enabled in Step 7, this step offers to remove the UFW rules that allow public SSH access - leaving SSH only reachable through your Tailnet.

**Why this is last and defaults to no**

Removing public SSH access before confirming that Tailscale SSH actually works is one of the most reliable ways to permanently lock yourself out of a server. The step only appears when Tailscale SSH was enabled in the same run. The warnings are explicit. Test first, then answer yes.

**When to say yes**

Only after:
1. The server appears in your Tailscale dashboard as connected
2. You've opened a second terminal and confirmed `tailscale ssh user@hostname` works
3. You're happy that Tailscale is the only access path going forward

---

### Step 9 - Docker

**What it does**

Installs Docker Engine and the Docker Compose plugin from Docker's official apt repository - not the version in Ubuntu or Debian's default repositories, which is typically multiple major versions behind. Enables the Docker service and adds the admin user to the `docker` group.

Packages installed: `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`.

**Why Docker's own repository**

The Docker version in Ubuntu's default apt sources can be years out of date. Docker's own repository gives you the current release with up-to-date security patches. The script adds Docker's GPG key and signs the repository source before installing anything.

**Why add the user to the `docker` group**

Without this, running Docker requires `sudo` every time. Adding the admin user to the `docker` group lets them run Docker commands directly. Worth knowing: `docker` group membership is effectively equivalent to root access since containers can mount the host filesystem. On a personal or small-team server where the admin is trusted, this is the standard setup.

---

### Step 10 - Automatic security updates

**What it does**

Installs `unattended-upgrades` and configures it to apply security updates daily. Auto-reboot is explicitly disabled so the server doesn't restart on you unexpectedly.

| Setting | Value |
|---|---|
| Update package lists | Daily |
| Download upgradeable packages | Daily |
| Apply unattended upgrades | Daily |
| Auto-clean interval | Every 7 days |
| Auto-reboot | **Disabled** |

**Why**

The most common way servers get compromised is through unpatched known vulnerabilities. Security updates for Ubuntu and Debian come out quickly when something is disclosed. Manually tracking and applying them on a personal server is discipline that degrades over time. Unattended upgrades keeps the baseline maintained without requiring it.

Auto-reboot is off because unexpected reboots disrupt running services. Kernel updates that need a reboot are infrequent. You want to choose when the server restarts. Check whether one is pending:

```bash
cat /run/reboot-required 2>/dev/null && echo "reboot needed" || echo "no reboot needed"
```

---

### Step 11 - Scheduled maintenance

**What it does**

Generates a maintenance script at `/usr/local/bin/vps-maintenance` and registers it as a weekly cron job in `/etc/cron.d/vps-maintenance` (Sunday at 03:00). You choose which tasks to include:

**Weekly full apt upgrade**

Runs `apt-get update`, `apt-get upgrade`, and `apt-get autoremove`. This goes further than unattended-upgrades, which only applies security patches - this upgrades everything and removes unused packages.

**Weekly Docker image updates**

Pulls the latest image for every currently running container:

```bash
docker ps --format "{{.Image}}" | sort -u | while read -r img; do
  docker pull "$img"
done
```

**Weekly Docker prune**

Removes dangling images and stopped containers to reclaim disk space. Equivalent to running `docker image prune -f && docker container prune -f` weekly without thinking about it.

**Optional Docker Compose restart**

If you provide a Compose project directory, the script runs `docker compose pull && docker compose up -d` in that directory after the image pull - so updated images are immediately in use, not just downloaded.

**Generated files**

| File | Purpose |
|---|---|
| `/usr/local/bin/vps-maintenance` | The maintenance script itself - readable and editable |
| `/etc/cron.d/vps-maintenance` | Cron entry (Sunday 03:00, runs as root) |
| `/var/log/vps-maintenance.log` | Output log, appended on each run |

The maintenance script is plain bash. Open it, read it, edit it. It's yours.

**Why separate from unattended-upgrades**

Unattended-upgrades is designed for security patches only - it's conservative by design. The weekly full upgrade catches non-security package updates, removes accumulated package cruft, and handles Docker images that `unattended-upgrades` knows nothing about.

---

### Step 12 - Verification

**What it does**

Runs a set of checks after the bootstrap to confirm everything is in a working state:

- `sshd -t` - validates SSH config syntax
- `ufw status` - shows active firewall rules
- `fail2ban-client status` - confirms fail2ban is running
- `systemctl is-active docker` - checks the Docker service
- `tailscale status` - retrieves Tailscale connection state if installed

**Why**

A change in one step can have side effects that only show up when you try to use the server. Running automated checks immediately after setup catches the most common issues before you close the terminal. Results go into the log file for future reference.

This doesn't replace testing manually. Open a new terminal and verify your own access path before closing the original session.

---

## CLI reference

```
Usage: sudo bash vps-bootstrap-v1.6.1.sh [options]

Options:
  --dry-run          Show what would happen without making any changes
  --verbose          Stream command output to the terminal as well as the log
  --only=a,b,c       Run only the specified steps (comma-separated)
  --skip=a,b,c       Skip the specified steps (comma-separated)
  -h, --help         Show this help
```

### `--dry-run`

Preview every action without changing anything. Prompts still appear; all writes, installs, and service restarts show as `(dry-run)`. Run this first on any server that's not a clean install.

```bash
sudo bash vps-bootstrap-v1.6.1.sh --dry-run
```

### `--verbose`

Stream command output live to the terminal instead of writing only to the log. Useful when a step is failing and you want to see what's happening.

```bash
sudo bash vps-bootstrap-v1.6.1.sh --verbose
```

### `--only`

Run specific steps, skip everything else. Useful for re-running a single step on an already-configured server.

```bash
sudo bash vps-bootstrap-v1.6.1.sh --only=docker,verify
```

### `--skip`

Run everything except the steps you name.

```bash
sudo bash vps-bootstrap-v1.6.1.sh --skip=git,tailscale,close-ssh
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
| `cron` | Scheduled maintenance jobs |
| `verify` | Final verification checks |

---

## Common workflows

### Fresh VPS - public SSH retained

Admin user, hardened SSH, firewall, fail2ban, Docker, auto-updates, scheduled maintenance. SSH stays on the internet on a custom port.

```bash
sudo bash vps-bootstrap-v1.6.1.sh
```

Suggested answers:
- Create admin user: **yes**
- Copy root SSH keys to new user: **yes**
- Change SSH port: **yes** - pick any port above 1024
- Disable root login: **yes** - after confirming the new user has SSH key access
- Disable password auth: **yes** - if key-based login is confirmed working
- Enable UFW: **yes** - allow 80/443 if running a web server
- Install fail2ban: **yes**
- Install Tailscale: **up to you** - I'd say yes
- Install Docker: **yes** if you need it
- Auto security updates: **yes**
- Weekly apt upgrade cron: **yes**
- Weekly Docker maintenance cron: **yes** if Docker is installed

---

### Tailscale-first VPS - no public SSH

SSH never exposed to the internet. The server is only reachable through your Tailnet. This is how I run most of my own servers.

```bash
sudo bash vps-bootstrap-v1.6.1.sh
```

Suggested answers:
- Create admin user: **yes**
- Copy root SSH keys: **yes**
- Disable root login: **yes**
- Enable UFW: **yes**
- Install fail2ban: **yes**
- Install Tailscale: **yes**
- Enable Tailscale SSH: **yes**
- **Open a second terminal. Run `tailscale ssh user@hostname`. Confirm it works before continuing.**
- Remove public SSH access: **yes** - only after the test above passes

---

### Re-run a single step

The script is safe to run multiple times. Adding Docker to an already-hardened server:

```bash
sudo bash vps-bootstrap-v1.6.1.sh --only=docker,verify
```

Adding Tailscale later:

```bash
sudo bash vps-bootstrap-v1.6.1.sh --only=tailscale
```

Setting up scheduled maintenance on an existing server:

```bash
sudo bash vps-bootstrap-v1.6.1.sh --only=cron
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

**Scheduled maintenance:**

```bash
# View the generated maintenance script
sudo cat /usr/local/bin/vps-maintenance

# View the cron entry
sudo cat /etc/cron.d/vps-maintenance

# Check the maintenance log after the first run
sudo tail -f /var/log/vps-maintenance.log
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

The path is printed at startup and in the final summary. The log records every command run with its full arguments, every file written with path, mode and owner, every service restart, and every timestamped action. Created with `chmod 600` - only root can read it.

The weekly maintenance job writes to its own log:

```
/var/log/vps-maintenance.log
```

---

## Security notes

**Never close your current session until the new one is tested.** Every SSH change, every firewall change, every decision to close public access - open a second terminal, confirm it works, then close the original. There is no other safe order.

**The script validates SSH config before restarting.** `sshd -t` runs before any SSH service restart. If there's a syntax error, the script stops and points you to the backup. Backups are written as `filename.bak.TIMESTAMP` before any changes are made.

**Password auth is blocked from being disabled if no SSH keys exist.** If the target user has no `authorized_keys` file, the option is not presented. The script tells you to add a key first, then re-run with `--only=ssh`.

**Run `--dry-run` on any non-fresh server.** The script is designed for clean installs. On an existing server, some steps may conflict with your current configuration.

---

## Project structure

```
.
├── README.md
└── vps-bootstrap-v1.6.1.sh
```

Recommended additions:

```
.
├── README.md
├── LICENSE
├── CHANGELOG.md
├── vps-bootstrap-v1.6.1.sh
└── examples/
    ├── sample-output.txt
    └── tailscale-first-runbook.md
```

---

## Roadmap

- **Drop-in SSH config** - write hardening to `/etc/ssh/sshd_config.d/` instead of editing the main file directly
- **Pinned GitHub host keys** - replace `ssh-keyscan` with verified fingerprints
- **Swap file creation** - useful on low-memory VPS instances
- **Hostname and timezone setup** - common first-boot tasks currently done manually
- **Shellcheck CI** - automated linting before release
- **Caddy / reverse proxy step** - optional setup for servers running web applications
- **Rollback hints** - better guidance when a step fails mid-way
- **Multiple Compose directories** - currently the cron step supports one Compose path; multi-stack support would be useful

---

## License

MIT License. See `LICENSE` for details.

---

## Inspiration and prior work

This script was built on top of ideas and patterns from two projects worth knowing about:

- **[akcryptoguy/vps-harden](https://github.com/akcryptoguy/vps-harden)** - a solid, straightforward VPS hardening script that covers the core bases clearly
- **[ranjith-src/vps-harden](https://github.com/ranjith-src/vps-harden)** - a very thorough hardening script with extensive module coverage including sysctl hardening, auditd, SOPS secret management, and more. Worth reading if you want to go deeper than ironboot does

Both are good references. If your requirements are more complex than what ironboot covers, ranjith-src's version in particular goes significantly further.
