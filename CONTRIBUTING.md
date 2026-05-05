# Contributing

ironboot is intentionally small. Changes should keep it readable, auditable, and safe to run over SSH.

## Rules

- Bash only unless there is a strong reason.
- No heavy dependencies.
- Preserve `--dry-run` behavior.
- Preserve SSH lockout safety checks.
- Keep prompts clear and conservative.
- Update README and tests for behavior changes.
- Run the smoke tests before opening a pull request.

## Local checks

```bash
bash -n ironboot.sh
shellcheck ironboot.sh tests/smoke.sh
bash tests/smoke.sh
```

Some smoke checks use `sudo --dry-run` behavior and will skip locally if passwordless sudo is unavailable.
Set `IRONBOOT_RUN_ROOT_SMOKE=1` to opt into the root dry-run check on a machine where sudo is safe to use.
