# Release Checklist

Run these before tagging a new release.

## Automated checks

```bash
bash -n ironboot.sh
shellcheck ironboot.sh tests/smoke.sh
bash tests/smoke.sh
IRONBOOT_RUN_ROOT_SMOKE=1 bash tests/smoke.sh
```

## Manual VPS checks

- Fresh Ubuntu LTS VPS.
- Fresh Debian stable VPS.
- Existing server rerun with `--only=auto-updates`.
- Existing server rerun with custom SSH port and `--only=fail2ban`.
- Tailscale already installed, rerun `--only=close-ssh`.
- Dry-run on an existing production-like host.

## Documentation checks

- README examples use `ironboot.sh`.
- README step list matches `ironboot.sh --help`.
- `CHANGELOG.md` has the new version.
- `SCRIPT_VERSION` matches the release tag.
