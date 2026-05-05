# Changelog

All notable changes to ironboot are documented here.

## 1.7.0 - 2026-05-05

### Added

- Stable `ironboot.sh` entrypoint.
- Explicit `system-update` step.
- `--yes` for accepting prompt defaults.
- `--ssh-port=PORT` for targeted firewall and fail2ban reruns.
- `--version`.
- Step-name validation for `--only` and `--skip`.
- ShellCheck and smoke-test CI.
- Release checklist and contribution guide.

### Changed

- `--only` now runs only selected step functions. It no longer performs an implicit full package update and upgrade before narrow reruns.
- UFW, fail2ban, and close-public-SSH reruns detect existing SSH/Tailscale state instead of relying only on variables from the same run.
- SSH hardening now prefers `/etc/ssh/sshd_config.d/99-ironboot.conf` when the distro includes drop-ins, with fallback to direct `sshd_config` edits.
- Generated files include ironboot ownership headers.
- Logs now use `/var/log/ironboot-YYYYmmdd-HHMMSS.log`.

### Fixed

- Help text now uses the invoked script name instead of an old versioned filename.
- Unknown step names now fail fast instead of silently skipping all work.

## 1.6.4

### Added

- Guided VPS bootstrap flow for Ubuntu and Debian.
- Admin user creation, SSH hardening, sysctl hardening, UFW, fail2ban, GitHub deploy key setup, Tailscale, Docker, automatic security updates, scheduled maintenance, and verification.
