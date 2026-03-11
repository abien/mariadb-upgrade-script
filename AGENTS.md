# AGENTS.md — MariaDB Upgrade Script

## Project Overview

Single-file Bash script (`mariadb-upgrade.sh`) that upgrades MariaDB across major versions on RHEL-family systems with Plesk. It detects the current version, builds a step-by-step upgrade path through intermediate versions, and applies post-upgrade configuration.

**Target environment**: CentOS 7, AlmaLinux/Rocky Linux 8, with Plesk installed.
**This script runs as root on production servers.** Every change must be safe and idempotent where possible.

## Repository Structure

```
mariadb-upgrade.sh          # The entire script (~580 lines)
README.md                   # User-facing documentation
.github/workflows/          # CI: ShellCheck on push to master
```

## Build / Lint / Test Commands

### Linting (the ONLY automated check)

```bash
# CI runs ShellCheck on every push to master
shellcheck mariadb-upgrade.sh

# Install locally if needed
# apt-get install shellcheck   (Debian/Ubuntu)
# dnf install ShellCheck       (RHEL/Alma)
```

### No test suite

There are no unit or integration tests. The script operates on live systems (rpm, yum, systemctl, mysql). Verification is manual on a test server or VM.

### Syntax check (quick local validation)

```bash
bash -n mariadb-upgrade.sh
```

## Code Style Guidelines

### Shell Basics

- Shebang: `#!/bin/bash` (not `sh`, not `env bash`)
- Line endings: LF only (enforced via `.gitattributes`)
- Indentation: **2 spaces**, no tabs
- No trailing whitespace

### Variables

- **Global constants**: `UPPER_CASE` — e.g., `RED`, `NC`, `LOG`, `TARGET_VERSION`
- **Function parameters**: `UPPER_CASE` — e.g., `MDB_VER=$1`, `MAJOR_VER`, `BASEURL`
- **Local/transient**: `lowercase` — e.g., `erroutput`, `installed_packages`, `mdb_ver`
- Always quote variables in arguments: `"$VAR"` not `$VAR`
  - Exception: `$LOG` is used unquoted throughout (existing pattern, don't change)

### Functions

- Naming: `lowercase_with_underscores` — e.g., `do_mariadb_upgrade`, `bind_address_fix`
- Define functions before the main logic block
- No `local` keyword is used (existing pattern)

### String Comparison and Conditionals

- Use `[[ ]]` for string matching and regex: `[[ $REPLY =~ ^[Yy]$ ]]`
- Use `[ ]` for simple equality in upgrade path logic: `[ "$TARGET_VERSION" = "11.4" ]`
- Combine OR conditions with `||` between separate `[ ]` tests:
  ```bash
  if [ "$TARGET_VERSION" = "11.4" ] || [ "$TARGET_VERSION" = "11.8" ]; then
  ```
- Use `case` statements for version detection routing (pattern: `*"Distrib X.Y."*`)

### Error Handling Pattern

The script uses a consistent error-capture pattern. **Follow this exactly:**

```bash
if erroutput=$(some_command 2>&1); then
  echo "- Success message" | tee -a $LOG
else
  echo -e "${RED}Failure message" | tee -a $LOG
  echo -e "$erroutput ${NC}" | tee -a $LOG
  exit 1   # or omit exit for non-fatal errors
fi
```

- Capture stderr into `erroutput` via command substitution
- On success: log a `- ` prefixed message
- On failure: log with `${RED}` color prefix, print captured error, then `${NC}` reset
- Fatal errors: `exit 1`. Non-fatal: log and continue

### Logging

- All user-visible output goes through `| tee -a $LOG`
- Log file: `/var/log/mariadb-upgrade.log`
- Progress messages are prefixed with `- ` (dash space)
- Section headers have no prefix (e.g., `"Beginning upgrade to MariaDB $MDB_VER..."`)

### ShellCheck Compliance

- The script MUST pass `shellcheck` cleanly
- Use `# shellcheck disable=SCXXXX` comments for intentional exceptions only
- Current exceptions in the codebase:
  - `SC2128` — using `$BASH_SOURCE` without index (intentional)
  - `SC1091` — not following sourced file `/etc/os-release` (external file)
- Never add new disable comments without a clear reason in a comment

### Version Upgrade Path Pattern

When adding a new target LTS version (e.g., 11.8), follow this pattern across ALL detected-version `case` branches:

```bash
# For versions that need intermediate steps to reach the new target:
if [ "$TARGET_VERSION" = "11.4" ] || [ "$TARGET_VERSION" = "11.8" ]; then
  do_mariadb_upgrade '11.4'
fi
if [ "$TARGET_VERSION" = "11.8" ]; then
  do_mariadb_upgrade '11.8'
fi

# For "already at version" cases:
*"Distrib 11.8."*)
  echo "Already at 11.8. Exiting." | tee -a $LOG
  exit 1
  ;;

# For versions between two LTS releases (e.g., 11.5-11.7 between 11.4 and 11.8):
*"Distrib 11.5."*)
  echo "MariaDB 11.5 detected. Proceeding with upgrade to $TARGET_VERSION" | tee -a $LOG
  do_mariadb_upgrade '11.8'
  ;;
```

**Upgrade path rules:**
- Always step through LTS versions in order (10.11 -> 11.4 -> 11.8)
- Short-lived releases between two LTS versions can jump directly to the next LTS
- Legacy versions (10.0-10.2) use archive.mariadb.org URLs; everything else uses yum.mariadb.org

### Adding a New Target Version Checklist

1. Add menu option in the version selection prompt (numbered choice)
2. Add `elif` branch in the choice-parsing block to set `TARGET_VERSION`
3. Update ALL existing `case` branches to include the new target in upgrade conditionals
4. Add `case` branches for any intermediate versions (non-LTS between previous and new LTS)
5. Add "already at version" `case` branch
6. Update `README.md`: description, supported versions list, upgrade paths section, usage text

### What NOT to Do

- **Never refactor the case-statement structure** into loops or arrays — the explicit paths are intentional for auditability on production servers
- **Never add dependencies** (no external scripts, no pip/npm, no downloaded binaries)
- **Never remove the backup prompt** — it's the user's safety net
- **Never change the `do_mariadb_upgrade` function signature** without updating every call site
- **Never suppress ShellCheck warnings** without documenting why
- **Never hardcode package version numbers** for the yum.mariadb.org URL pattern (the `*` default case handles current versions dynamically)

## CI Pipeline

- **Trigger**: Push to `master` branch
- **Action**: `ludeeus/action-shellcheck@master` runs ShellCheck on all `.sh` files
- **No other CI steps** (no build, no test, no deploy)

## Git Conventions

- Default branch: `master`
- Commit style: short imperative subjects (e.g., `feat: add MariaDB 11.4 LTS upgrade option`)
- PRs merged via GitHub

## Key Architecture Decisions

1. **Single file by design** — the script is `scp`'d to servers and run. No module system, no sourced files.
2. **Sequential upgrade steps** — each `do_mariadb_upgrade` call stops the DB, swaps packages, restarts, and runs `mysql_upgrade`. Order matters.
3. **Plesk integration** — backup uses Plesk's admin password, post-upgrade notifies Plesk via `packagemng`. Without Plesk, the script won't work.
4. **The case block is the routing table** — version detection maps to upgrade chains. It's deliberately verbose for clarity.
