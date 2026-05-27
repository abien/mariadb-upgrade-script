# Description
Upgrade MariaDB from 5.5/10.x/11.x to MariaDB 10.11 LTS, 11.4 LTS, or 11.8 LTS on CentOS 7 and AlmaLinux/Rocky Linux 8, intended for Plesk environments. The script also configures MariaDB so you can run `mysqladmin` without entering credentials interactively.

It integrates with Plesk to perform backups, run upgrades, and notify Plesk of version changes.

## Supported Target Versions
- MariaDB 10.11 LTS
- MariaDB 11.4 LTS
- MariaDB 11.8 LTS

## Requirements
- Root privileges (`root` or `sudo`).
- RHEL-family OS: CentOS 7, AlmaLinux 8, Rocky Linux 8 (RHEL 8 generally also works).
- Plesk installed (the script uses `plesk` tools and `/etc/psa/.psa.shadow`).
- YUM/DNF package manager (Debian/Ubuntu are not supported).

## What It Does
- Optional full backup of all databases via `mysqldump` to `/root/all_databases_pre_maria_upgrade.sql.gz`.
- Configures MariaDB repositories per upgrade step, using archived repositories for EOL intermediate releases.
- Stops services, removes incompatible packages, installs target packages.
- Runs `mysql_upgrade` and applies sensible defaults in `server.cnf` (e.g., `max_allowed_packet`, `open_files_limit`, log link).
- Notifies Plesk about package changes and enables `unix_socket` so `mysqladmin` can be used without a password.
- Writes a log to `/var/log/mariadb-upgrade.log`.

## Upgrade Paths
The script detects the current version and chooses the correct path automatically.

### Target: MariaDB 10.11 LTS
- From 5.5: 5.5 → 10.0 → 10.5 → 10.6 → 10.11
- From 5.6: 5.6 → 10.0 → 10.1 → 10.2 → 10.5 → 10.6 → 10.11
- From 10.0: 10.0 → 10.1 → 10.2 → 10.5 → 10.6 → 10.11
- From 10.1: 10.1 → 10.2 → 10.5 → 10.6 → 10.11
- From 10.2: 10.2 → 10.5 → 10.6 → 10.11
- From 10.3–10.4: 10.x → 10.5 → 10.6 → 10.11
- From 10.5: 10.5 → 10.6 → 10.11
- From 10.6–10.10: 10.x → 10.11

### Target: MariaDB 11.4 LTS
- From 5.5: 5.5 → 10.0 → 10.5 → 10.6 → 10.11 → 11.4
- From 5.6: 5.6 → 10.0 → 10.1 → 10.2 → 10.5 → 10.6 → 10.11 → 11.4
- From 10.x: (first upgrade to 10.11) → 11.4
- From 11.0–11.3: 11.x → 11.4

### Target: MariaDB 11.8 LTS
- From 5.5: 5.5 → 10.0 → 10.5 → 10.6 → 10.11 → 11.4 → 11.8
- From 5.6: 5.6 → 10.0 → 10.1 → 10.2 → 10.5 → 10.6 → 10.11 → 11.4 → 11.8
- From 10.x: (first upgrade to 10.11) → 11.4 → 11.8
- From 11.0–11.3: 11.x → 11.4 → 11.8
- From 11.4: 11.4 → 11.8
- From 11.5–11.7: 11.x → 11.8

## Usage
Run the script as `root`:

```
chmod +x mariadb-upgrade.sh
./mariadb-upgrade.sh
```

The script will prompt you to:
1. Choose whether to back up databases (recommended)
2. Select a target version (10.11, 11.4, or 11.8)
3. Confirm the upgrade

## Notes & Limitations
- Designed for Plesk installations; without Plesk some steps (e.g., backup/user plugins) do not apply.
- Only YUM/DNF-based distributions are supported (no Debian/Ubuntu).
- The script updates `/etc/yum.repos.d/mariadb.repo` and uses version-pinned repositories for each upgrade step.
