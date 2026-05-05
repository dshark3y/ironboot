# Proposed Changes To Bring ironboot To An A

## Goal

Make this repo safe to recommend for real VPS hardening work: predictable reruns, clear documentation, tested shell behavior, clean release hygiene, and no avoidable lockout or maintenance surprises.

The repo is already useful. The path to an A is not a rewrite. It is a focused hardening pass around idempotency, single-step execution, validation, and project hygiene.

Implementation note: this proposal has been applied in the `1.7.0` pass. The file remains as the rationale and checklist behind the changes.

## Priority 1 - Fix Rerun Semantics

### 1. Make `--only` truly run only selected steps

Current behavior:

```bash
sudo bash ironboot.sh --only=auto-updates
```

still runs the top-level `apt-get update` and `apt-get upgrade` before the selected step.

Proposed behavior:

- `--only=auto-updates` should only run root checks, OS detection, logging setup, then the `auto-updates` step.
- Top-level apt update/upgrade should become its own explicit step, for example `system-update`.
- Fresh default runs should include `system-update`.
- Single-step reruns should not perform unrelated upgrades.

This matters because users running a narrow fix on an existing production server should not receive unrelated package upgrades.

### 2. Detect current server state for single-step reruns

Some steps depend on variables set earlier in the same run. Those variables are missing during `--only` reruns.

Examples:

- `ufw` uses `SSH_PORT_FINAL:-22`.
- `fail2ban` writes `port = ${SSH_PORT_FINAL:-22}`.
- `close-ssh` only runs if `TAILSCALE_SSH_RESULT` was set in this same script execution.

Proposed changes:

- Add a small `detect_current_ssh_port` helper that reads the active SSH port from `/etc/ssh/sshd_config`.
- Use detected SSH state whenever `SSH_PORT_FINAL` is unset.
- Detect whether Tailscale is installed and whether `tailscale status` works before deciding whether `close-ssh` can proceed.
- Keep prompts explicit before removing firewall access.

### 3. Add a first-class auto-updates rerun workflow

Add a documented command:

```bash
sudo bash ironboot.sh --only=auto-updates
```

Expected changes on the target machine:

- Install `unattended-upgrades`.
- Install `apt-listchanges`.
- Write `/etc/apt/apt.conf.d/20auto-upgrades`.
- Write `/etc/apt/apt.conf.d/52unattended-upgrades-local`.
- Enable and restart `unattended-upgrades`.

Expected non-changes:

- No SSH edits.
- No firewall edits.
- No Docker install.
- No Tailscale install.
- No full system upgrade unless the user explicitly selected that step.

## Priority 2 - Improve Safety And Idempotency

### 4. Validate step names

Today, a typo like this:

```bash
sudo bash ironboot.sh --only=auto-update
```

silently skips every step after the initial setup work.

Proposed behavior:

- Validate every `--only` and `--skip` value against the known step list.
- Fail fast on unknown step names.
- Print valid step names in the error.

### 5. Make file writes visibly owned by ironboot

For files fully managed by the script, keep the current overwrite model but make ownership clear.

Proposed changes:

- Add a header to generated files saying they are managed by ironboot.
- Keep backups for sensitive existing files before modification.
- For SSH config, prefer a drop-in file under `/etc/ssh/sshd_config.d/` when supported, rather than repeatedly editing the main config.

### 6. Harden command failure handling around piped installers

The Docker and Tailscale install paths use network fetches and pipes. They are common failure points.

Proposed changes:

- Make failures explicit and readable in non-verbose mode.
- Ensure spinners always stop on pipe failures.
- Prefer downloaded script/key validation where practical.
- Keep the current simple approach; do not add a full installer framework.

### 7. Add noninteractive affordances only where useful

The script should remain guided and interactive by default. Add noninteractive flags only for common rerun-safe operations.

Useful candidates:

- `--yes` for accepting safe defaults.
- `--no-upgrade` if top-level package upgrade remains outside a step.
- `--ssh-port=PORT` for rerunning `ufw` or `fail2ban`.

Avoid a large config language unless there is clear demand.

## Priority 3 - Add Verification

### 8. Add ShellCheck

Add a minimal lint workflow:

- `.shellcheckrc`
- GitHub Actions workflow for ShellCheck
- Document how to run it locally

Target command:

```bash
shellcheck ironboot.sh
```

### 9. Add smoke tests with a container

Use a lightweight Docker-based test harness for syntax and basic dry-run behavior.

Suggested checks:

- `bash -n ironboot.sh`
- `--help` exits cleanly.
- Invalid step names fail.
- `--dry-run --only=auto-updates` does not attempt unrelated steps.
- Generated auto-updates files contain expected apt periodic settings.

This does not need to simulate every VPS behavior. The goal is to catch regressions in script flow.

### 10. Add a manual QA checklist

Create a short release checklist for real Ubuntu/Debian VPS testing:

- Fresh Ubuntu LTS VPS.
- Fresh Debian stable VPS.
- Existing server rerun with `--only=auto-updates`.
- Existing server rerun with custom SSH port and `--only=fail2ban`.
- Tailscale already installed, rerun `--only=close-ssh`.
- Dry-run on an existing production-like host.

## Priority 4 - Clean Repo Hygiene

### 11. Clean tracked and untracked project files

Current workspace contains local/untracked artifacts that should not be part of the project surface:

- `.DS_Store`
- old script copies
- files with spaces in script names

Proposed changes:

- Add `.gitignore`.
- Keep only the current maintained script in the main path.
- Move old versions to `archive/` only if they are intentionally retained.
- Otherwise remove old script copies from the working tree.

### 12. Rename the script to a stable install name

Versioned filenames make curl examples and docs drift.

Proposed structure:

```text
ironboot.sh
README.md
CHANGELOG.md
PROPOSED_CHANGES.md
```

Release tags can carry the version. The script itself can still expose `SCRIPT_VERSION`.

### 13. Fix documentation drift

Current help text says:

```text
Usage: sudo bash ironboot.sh [options]
```

but the script version is `1.6.4`.

Proposed changes:

- Use the actual invoked script name in help text: `$(basename "$0")`.
- Keep README examples aligned with the stable script name.
- Add a dedicated "Rerun Recipes" section.

## Priority 5 - Improve Trust

### 14. Add a threat model section

Keep it plain English.

Cover:

- What this script protects against.
- What it does not protect against.
- Why Tailscale is recommended.
- Why automatic security updates are enabled without automatic reboot.
- How to recover if SSH changes go wrong.

### 15. Add a changelog

Add `CHANGELOG.md` with concise release notes:

- Added
- Changed
- Fixed
- Security

This matters because users running a VPS hardening script need to know what changed between versions.

### 16. Add license and contribution boundaries

Add:

- `LICENSE`
- `CONTRIBUTING.md` if external contributions are expected

Keep contribution rules simple:

- Bash only unless strongly justified.
- No heavy dependencies.
- Must preserve dry-run behavior.
- Must preserve lockout safety checks.
- Must update README and tests for behavioral changes.

## Recommended Implementation Order

1. Add `.gitignore`, fix help text, and add step-name validation.
2. Move top-level package update/upgrade into an explicit `system-update` step.
3. Add current-state detection for SSH port and Tailscale status.
4. Document `--only=auto-updates` as a supported existing-server workflow.
5. Add ShellCheck and basic smoke tests.
6. Rename the script to a stable `ironboot.sh` entrypoint.
7. Add changelog, license, and release checklist.

## Definition Of Done

The repo reaches an A when all of this is true:

- A user can safely run `--only=auto-updates` on an existing VPS without unrelated changes.
- Single-step reruns behave correctly even when earlier steps were not run in the same execution.
- Unknown step names fail fast.
- Shell syntax and ShellCheck run in CI.
- README examples match the script.
- The working tree contains no local artifacts or confusing duplicate scripts.
- The repo has a stable entrypoint, changelog, license, and release checklist.
- The script remains simple Bash, with no unnecessary framework or dependency creep.
