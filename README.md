# SysSentry

[![GitHub](https://img.shields.io/badge/GitHub-0xSenior%2FSysSentry-blue?logo=github)](https://github.com/0xSenior/SysSentry)
[![ShellCheck](https://img.shields.io/badge/Lint-ShellCheck-brightgreen)](https://github.com/koalaman/shellcheck)
[![Bash](https://img.shields.io/badge/Language-Bash%205.x-4EAA25?logo=gnubash)](https://www.gnu.org/software/bash/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://img.shields.io/github/actions/workflow/status/0xSenior/SysSentry/.github/workflows/ci.yml?label=CI)](https://github.com/0xSenior/SysSentry/actions)

> **SysSentry** — a high-performance, pure-Bash Linux CLI system utility that bridges
> real-time OS resource monitoring, rogue process governance, and automated
> resource-safe incremental backups.

Built as a showcase of **Systems Programming**, **Operating Systems internals**,
**Data Structures**, and **Clean Architecture in Shell scripting**.

---

## 📦 Repository Layout (Clean Architecture)

```
SysSentry/
├── .github/
│   └── workflows/
│       └── ci.yml               # ShellCheck linter & static validation
├── bin/
│   └── syssentry                # Main executable entrypoint (CLI Dispatcher)
├── config/
│   └── syssentry.conf.example   # Configuration profile (thresholds, paths, retention)
├── lib/
│   ├── core.sh                  # Pseudo-OOP structs, logger, signal traps, error handler
│   ├── monitor.sh               # Virtual filesystem inspector (/proc parser)
│   ├── process.sh               # Process controller, safety whitelist, signal cascade
│   └── backup.sh                # Incremental archiving, pre-flight checks, retention
├── tests/
│   └── test_smoke.sh            # Automated verification & test suite
├── .gitignore                   # Ignores archives, logs, runtime dumps
├── LICENSE                      # MIT License
└── README.md                    # This file
```

---

## 🏗️ Architecture

SysSentry follows a **modular, layered design** with strict separation of concerns.
Each module exposes a namespaced API (`Core::`, `Monitor::`, `Process::`,
`Backup::`) and communicates through pseudo-OOP entity structs implemented as
Bash associative arrays.

```text
┌─────────────────────────────────────────────────────────────────────┐
│                       bin/syssentry  (CLI Dispatcher)               │
│  monitor  |  backup  |  guard  |  clean  | --help | --version       │
└─────────────┬────────┬─────────┬─────────┬──────────┬───────────────┘
              │        │         │         │          │
   ┌──────────▼──┐ ┌────▼────┐ ┌─▼────┐ ┌─▼────┐ ┌───▼────┐
   │ Monitor::   │ │ Backup:: │ │Proc::│ │Backup│ │ Core:: │
   │ capture_snapshot│ │ run_backup │ │govern│ │retention│ │ log/init/ │
   │ classify_health │ │ pre_flight │ │terminate│ │_clean │ │ help    │
   └─────────────┘ └─────────┘ └──────┘ └──────┘ └────────┘
              │        │         │         │
              └────────┴─────────┴────────┘
                       │
              ┌────────▼────────┐
              │   Core:: entities  │
              │  SystemSnapshot   │
              │  ProcessRecord    │
              │  BackupJob        │
              │ (assoc. arrays)   │
              └────────┬────────┘
                       │
              ┌────────▼────────┐
              │   /proc, /sys, tar │
              │   Kernel metrics   │
              └─────────────────┘
```

### Data Flow

1. **Monitor** reads `/proc/meminfo`, `/proc/loadavg`, `/proc/stat` → builds a
   `SystemSnapshot` entity → classifies health as `NORMAL` / `WARNING` / `CRITICAL`.
2. **Process Governor** scans `/proc/*/stat` in a single O(N) pass → flags rogue
   processes → enforces a `SIGTERM → grace-wait → SIGKILL` cascade, skipping
   PIDs in the O(1) protection whitelist (PID 1, kernel daemons, self, parent).
3. **Backup Engine** runs a pre-flight safety gate (aborts if `CRITICAL`) →
   creates timestamped `tar + gzip` archives (full or incremental via `-g`)
   → prunes archives older than the retention window in O(N).

---

## ⚡ Algorithmic Efficiency & Big-O

SysSentry is engineered for **constant-time lookups** and **linear-time stream
processing**, avoiding subshell bottlenecks in hot paths.

### Complexity Table

| Operation | Algorithm | Complexity | Notes |
|-----------|-----------|------------|-------|
| Config lookup | Hash map (`declare -A`) | **O(1)** | `Core::config_get` |
| Protected-PID check | Hash map lookup | **O(1)** | `Process::is_protected_pid` |
| Snapshot entity access | Hash map access | **O(1)** | `SystemSnapshot::get/set` |
| `/proc/meminfo` parse | Single-pass `while read` | **O(1)** | Fixed number of fields |
| `/proc/stat` parse | Single-pass `while read` | **O(1)** | Aggregate `cpu ` line only |
| Rogue-process scan | Single pass over `/proc/[0-9]*` | **O(N)** | N = number of processes |
| Termination cascade | SIGTERM → poll → SIGKILL | **O(G)** | G = grace-period polls |
| Incremental backup diff | `tar -g` snapshot metadata | **O(N)** | N = changed files |
| Retention cleaning | Single `find -mtime` pass | **O(N)** | N = archives in destination |

### Key Optimisations

- **No `$(...)` command substitution inside loops** — all `/proc` parsing uses
  Bash built-in `read` with stream redirection (`< /proc/...`).
- **Associative arrays** for O(1) whitelisted-PID and config lookups — no
  linear scans to decide whether a PID is protected.
- **`find -newer` / `tar -g` snapshot anchors** for incremental diffing by file
  metadata instead of full-content hash recalculation.
- **`set -euo pipefail`** defensive mode with trapped `ERR`/`EXIT`/`INT`/`TERM`.

---

## 🚀 Installation

### Prerequisites

- **Bash 4.0+** (associative arrays required)
- **tar**, **gzip**, **find**, **stat**, **date** (coreutils)
- **root** privileges required for process governance and backups of system paths

### From Source

```bash
# Clone the repository
git clone https://github.com/0xSenior/SysSentry.git
cd SysSentry

# Make the entrypoint executable
chmod +x bin/syssentry

# Copy and customise the configuration profile
cp config/syssentry.conf.example config/syssentry.conf
# Edit config/syssentry.conf to tune thresholds, paths, retention

# Run
./bin/syssentry --help
```

### System-Wide Install (optional)

```bash
sudo cp bin/syssentry /usr/local/bin/syssentry
sudo mkdir -p /etc/syssentry
sudo cp config/syssentry.conf.example /etc/syssentry/syssentry.conf
# Then run from anywhere:
syssentry monitor
```

---

## 🖥️ CLI Usage

```bash
syssentry <subcommand> [options] [--dry-run]
```

### Subcommands

| Subcommand | Description |
|------------|-------------|
| `monitor` | Capture and display a real-time system resource snapshot (RAM, CPU, IO wait, load, health state) |
| `backup <source> <dest> [full\|incremental]` | Create a timestamped gzip-compressed tar backup. Default: `full` |
| `guard [source] [dest]` | All-in-one: monitor health → backup (if safe) → govern rogue processes |
| `clean <dest> [days]` | Prune backup archives older than the retention window (default 7 days) |

### Global Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Simulate actions without modifying the system |
| `--help`, `-h` | Show help message |
| `--version`, `-v` | Show version |

### Examples

```bash
# 1. View current system health
./bin/syssentry monitor

# 2. Full backup of /home to /var/backups/syssentry
sudo ./bin/syssentry backup /home /var/backups/syssentry full

# 3. Incremental backup (only changed files since last snapshot)
sudo ./bin/syssentry backup /var/www /mnt/backups incremental

# 4. Simulate a backup without writing anything (safe to run anywhere)
./bin/syssentry backup /home /tmp/backup-test --dry-run

# 5. All-in-one guard cycle (monitor + backup + process governance)
sudo ./bin/syssentry guard /home /var/backups/syssentry

# 6. Prune archives older than 7 days
sudo ./bin/syssentry clean /var/backups/syssentry 7

# 7. Dry-run retention (see what would be pruned)
sudo ./bin/syssentry clean /var/backups/syssentry 7 --dry-run

# 8. Version & help
./bin/syssentry --version
./bin/syssentry --help
```

### Sample `monitor` Output

```
┌─ SysSentry System Snapshot ─
  Host:      server01
  Time:      2026-10-16 02:01:40

  Resource%│ %Used   Threshold%
  ─────────┼──────────────────
  MEM    │ 34.1%   (warn 80 / crit 90)
  CPU    │ 18.2%   (warn 75 / crit 85)
  IOwait │ 12.7%   (warn 15 / crit 30)

  Load avg:  1m=13.83  5m=9.00  15m=4.93

  Health:    CRITICAL  (score=3)
└────────────────────────────────
```

Events are also logged persistently to `syssentry.log`:

```
[2026-10-16 02:01:40] [CRIT] Backup pre-flight ABORTED: system health is CRITICAL
[2026-10-16 02:01:40] [INFO] Monitor check complete (state=CRITICAL)
```

---

## ⚙️ Configuration

Copy `config/syssentry.conf.example` to `config/syssentry.conf` and tune:

```ini
# --- Health thresholds ---
warn_mem_percent=80
crit_mem_percent=90
warn_cpu_percent=75
crit_cpu_percent=85
warn_load_1min=4.0
crit_load_1min=8.0
warn_io_wait_percent=15
crit_io_wait_percent=30

# --- Process governance ---
warn_mem_percent_proc=10
warn_cpu_percent_proc=10
grace_seconds=5
protected_pids=

# --- Backup settings ---
backup_source=/home
backup_dest=/var/backups/syssentry
backup_type=incremental
retention_days=7
```

All values are loaded into the `Core_CONFIG` hash map for **O(1)** lookups at
runtime.

---

## 🧪 Testing

```bash
# Run the automated smoke test suite
./tests/test_smoke.sh
```

The suite verifies: core initialisation, pseudo-OOP entity accessors, monitor
snapshot capture, O(1) PID-protection whitelist, config hash-map lookups,
backup pre-flight gating, retention cleanup, and CLI entrypoint.

### CI

GitHub Actions runs on every push/PR:

- **ShellCheck** static analysis on all shell scripts
- `bash -n` syntax validation
- Required-file presence checks
- Entrypoint `--help` / `--version` smoke check

See `.github/workflows/ci.yml`.

---

## 🛡️ Safety Guarantees

| Guarantee | Mechanism |
|-----------|-----------|
| No accidental self-termination | `$$` and `$PPID` in O(1) protection whitelist |
| No kernel / init interruption | PID 1 + low kernel-daemon PIDs protected |
| Graceful termination | `SIGTERM` → non-blocking grace-wait → `SIGKILL` only on refusal |
| Backup never starves a sick host | Pre-flight gate aborts when health is `CRITICAL` |
| Defensive execution | `set -euo pipefail`; trapped `ERR`/`EXIT`/`INT`/`TERM` |
| Temp-file hygiene | Registered temp files cleaned on exit |

---

## 📊 Project Metrics

| Aspect | Value |
|--------|-------|
| Language | Pure Bash (no external dependencies beyond coreutils) |
| Lines of code | ~850 (lib + bin + tests) |
| Modules | 4 (`core`, `monitor`, `process`, `backup`) |
| Entity structs | 3 (`SystemSnapshot`, `ProcessRecord`, `BackupJob`) |
| Lookup complexity | O(1) via associative arrays |
| Scan complexity | O(N) single-pass |
| License | MIT |

---

## 🤝 Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/your-feature`)
3. Run `shellcheck` and `bash -n` on your changes
4. Run `./tests/test_smoke.sh` to verify
5. Commit with a descriptive message
6. Open a Pull Request

All shell scripts must pass ShellCheck and `bash -n` before merging (enforced by CI).

---

## 📄 License

SysSentry is licensed under the [MIT License](LICENSE).

```
Copyright (c) 2026 Ahmed Harby (0xSenior)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, ...
```

---

**Author / Maintainer:** Ahmed Harby — [0xSenior](https://github.com/0xSenior)

**Repository:** https://github.com/0xSenior/SysSentry

> *"Monitoring with intent, governing with care, backing up safely."*
