#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.." || exit 1

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if ! grep -q "$needle" <<< "$haystack"; then
    echo "Expected output to contain: $needle" >&2
    echo "--- output ---" >&2
    printf '%s\n' "$haystack" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  if grep -q "$needle" <<< "$haystack"; then
    echo "Expected output not to contain: $needle" >&2
    echo "--- output ---" >&2
    printf '%s\n' "$haystack" >&2
    exit 1
  fi
}

bash -n ironboot.sh

help_output="$(bash ironboot.sh --help)"
assert_contains "$help_output" "Usage: sudo bash"
assert_contains "$help_output" "system-update"
assert_contains "$help_output" "auto-updates"

version_output="$(bash ironboot.sh --version)"
[[ "$version_output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]

invalid_output=""
if invalid_output="$(bash ironboot.sh --only=auto-update 2>&1)"; then
  echo "Expected invalid step name to fail" >&2
  exit 1
fi
assert_contains "$invalid_output" "Unknown step 'auto-update'"

grep -q 'APT::Periodic::Unattended-Upgrade "1";' ironboot.sh
grep -q 'Unattended-Upgrade::Automatic-Reboot "false";' ironboot.sh

if [[ "${IRONBOOT_RUN_ROOT_SMOKE:-0}" != "1" ]]; then
  echo "Skipping sudo dry-run smoke test; set IRONBOOT_RUN_ROOT_SMOKE=1 to enable."
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  if ! dry_run_output="$(sudo -n bash ironboot.sh --dry-run --yes --only=auto-updates 2>&1)"; then
    echo "Dry-run auto-updates command failed" >&2
    echo "--- output ---" >&2
    printf '%s\n' "$dry_run_output" >&2
    exit 1
  fi
  assert_contains "$dry_run_output" "Automatic security updates"
  assert_contains "$dry_run_output" "Install packages: unattended-upgrades apt-listchanges"
  assert_not_contains "$dry_run_output" "System package update"
  assert_not_contains "$dry_run_output" "SSH hardening"
else
  echo "Skipping sudo dry-run smoke test; passwordless sudo is unavailable."
fi
