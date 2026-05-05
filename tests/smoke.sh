#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.." || exit 1

bash -n ironboot.sh

help_output="$(bash ironboot.sh --help)"
grep -q "Usage: sudo bash" <<< "$help_output"
grep -q "system-update" <<< "$help_output"
grep -q "auto-updates" <<< "$help_output"

version_output="$(bash ironboot.sh --version)"
[[ "$version_output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]

invalid_output=""
if invalid_output="$(bash ironboot.sh --only=auto-update 2>&1)"; then
  echo "Expected invalid step name to fail" >&2
  exit 1
fi
grep -q "Unknown step 'auto-update'" <<< "$invalid_output"

grep -q 'APT::Periodic::Unattended-Upgrade "1";' ironboot.sh
grep -q 'Unattended-Upgrade::Automatic-Reboot "false";' ironboot.sh

if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  dry_run_output="$(sudo bash ironboot.sh --dry-run --yes --only=auto-updates 2>&1)"
  grep -q "Automatic security updates" <<< "$dry_run_output"
  grep -q "Install packages: unattended-upgrades apt-listchanges" <<< "$dry_run_output"
  if grep -q "System package update" <<< "$dry_run_output"; then
    echo "--only=auto-updates unexpectedly ran system-update" >&2
    exit 1
  fi
  if grep -q "SSH hardening" <<< "$dry_run_output"; then
    echo "--only=auto-updates unexpectedly ran ssh hardening" >&2
    exit 1
  fi
else
  echo "Skipping sudo dry-run smoke test; passwordless sudo is unavailable."
fi
