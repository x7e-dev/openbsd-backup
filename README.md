# OpenBSD Unified Backup & Rapid Disaster Recovery

A robust, profile-driven backup and bare-metal disaster recovery toolkit engineered specifically for OpenBSD. Written in pure OpenBSD Korn Shell (`/bin/ksh`), it captures system configurations, user dotfiles, running services, database dumps, and complete hardware/storage geometries for deterministic, rapid restoration.

Engineered with specialized support for:
- **Bare-metal Physical Servers:** Hardware RAID controllers, softraid crypto volumes, environmental sensors, bonded network interfaces (`trunk`/`aggr`/`carp`), PF firewall rules, daemon chroots, and databases.
- **Workstation Desktops:** Multi-monitor topologies (`xrandr`), audio DAC levels (`mixerctl`/`audioctl`), console mappings (`wsconsctl`), desktop fonts, and smart cache exclusions.
- **Laptops & Mobile Notebooks:** Battery health checks, APM power management (`apmd`), touchpad tapping/scrolling tuning, display backlight, and wireless network configurations.
- **Cloud VPS & Virtual Machines:** VirtIO storage/networking (`vioblk`/`vio`), cloud-init / autoinstall configs, serial console redirection (`boot.conf` `set tty com0`), memory-conscious compression, and low-disk scratch awareness.
- **Rapid Config Sync:** Lightweight dotfile and `/etc` sync (<20MB) across any environment.

---

## Table of Contents

- [Key Highlights](#key-highlights)
- [Architecture & Archive Anatomy](#architecture--archive-anatomy)
- [Profiles & Auto-Detection](#profiles--auto-detection)
- [Prerequisites & Installation](#prerequisites--installation)
- [Quick Start](#quick-start)
  - [1. Creating Backups (`backup.ksh`)](#1-creating-backups-backupksh)
  - [2. Inspecting & Restoring (`restore.ksh`)](#2-inspecting--restoring-restoreksh)
- [Privilege & Permissions Matrix](#privilege--permissions-matrix)
- [Complete Command Reference](#complete-command-reference)
  - [`backup.ksh`](#backupksh)
  - [`restore.ksh`](#restoreksh)
- [Exclusion Rules & Custom Filtering](#exclusion-rules--custom-filtering)
- [Disaster Recovery Guides by Environment](#disaster-recovery-guides-by-environment)
  - [1. Bare-Metal Physical Servers](#1-bare-metal-physical-servers)
  - [2. Laptops & Mobile Notebooks](#2-laptops--mobile-notebooks)
  - [3. Cloud VPS & Virtual Machines](#3-cloud-vps--virtual-machines)
  - [4. Restoring Database Dumps](#4-restoring-database-dumps)
- [Autonomous Emergency Recovery (`quick-restore.sh`)](#autonomous-emergency-recovery-quick-restoresh)
- [Automated Scheduling with `cron`](#automated-scheduling-with-cron)
- [Testing & Verification](#testing--verification)
- [License](#license)

---

## Key Highlights

- **Unified Multi-Platform Engine:** A single, maintainable backup script ([`backup.ksh`](backup.ksh)) with intelligent multi-factor hardware auto-detection across baremetal servers, desktops, laptops, and cloud VPS instances.
- **Turnkey Disaster Recovery:** A dedicated restoration engine ([`restore.ksh`](restore.ksh)) featuring SHA256 verification, pre-apply unified diffing (`--diff`), dry-run simulations (`--dry-run`), and full bare-metal rebuilding (`--all`).
- **Autonomous Emergency Helper:** Every archive embeds an executable `_sysinfo/quick-restore.sh` helper, enabling guided disaster recovery even if `restore.ksh` is not present on the rescue media.
- **Bare-Metal Storage & Hardware Metadata:** Automatically preserves DUIDs, active mount points (`fstab`), per-disk `fdisk` geometries, `disklabel` slice allocations, encrypted softraid / hardware RAID (`bioctl`) volume mappings, sensors, and bootloader settings (`boot.conf`).
- **Form-Factor & Partition Safeguards:**
  - **Direct-to-Destination Staging:** Stages temporary archives directly in the target destination filesystem rather than `/tmp`, bypassing OpenBSD's small (500MB–1GB) `/tmp` slice and avoiding cross-device copy overhead.
  - **Root Slice Space Guard:** Automatically detects if the destination is on the root filesystem (`/`) and warns the user to prevent filling OpenBSD's typically small (1–2GB) `/` slice.
  - **Strict Recursion & Loop Prevention:** Always excludes prior backups (`*_backup_*.tar.*`, `*.tar.gz`, `*.tar.xz`), temporary staging files, and foreign/network mountpoints (NFS, FUSE/sshfs, mfs) to avoid self-ingestion and exponential archive growth.
  - **Native OpenBSD tar(1) Compatibility:** Leverages OpenBSD `tar(1)` / `pax(1)` native `-s replstr` regular expression pattern substitution (`-s ',pattern,,'`) instead of unsupported GNU `--exclude` flags, guaranteeing 100% stock base OpenBSD compatibility without external packages (`gtar`).
  - **UNIX Domain Socket Exclusions:** Proactively skips active IPC sockets (`.gnupg/S.*`, `*.sock`, `*.socket`), preventing OpenBSD `ustar` archiving errors and socket corruption.
  - **Laptop Battery Protection:** Pre-flight battery check warns or prevents running heavy compression operations on low battery (≤ 20%) to avoid sudden shutdown.
  - **Adaptive Multi-Core XZ Compression:** Uses multi-threaded compression (`-T0`) on systems with > 1GB RAM, while restricting XZ dictionary memory on low-memory VPS instances (≤ 1GB RAM) to prevent kernel OOM killer panics.
- **Hardened Security by Default:** Enforces `umask 077` throughout execution (`0600` archive / `0700` working directories), guaranteeing sensitive data (such as `/etc/master.passwd`, SSH host keys, WireGuard keys, and database dumps) is never world-readable.
- **Production-Grade Reliability:**
  - File locking (`/var/run/openbsd-backup.lock`) with active PID detection to prevent overlapping cron runs.
  - Pre-flight storage checks (`df -k`) on scratch and target directories.
  - Streaming database compression (`.sql.gz`) to preserve scratch storage.
  - Proactive UNIX domain socket filtering with post-creation integrity validation (`tar -tzf` / `-tJf`).
  - True atomic archive deployment (same-filesystem instantaneous rename).
  - Preserves invoking user ownership (`$DOAS_USER`) so non-root users can manage their archives.
  - Automated retention pruning (`--keep N`) for archives and companion `.sha256` files.
  - Offsite SCP upload preserving user SSH identity and authentication agent (`su -l "$DOAS_USER"`).

---

## Architecture & Archive Anatomy

Each generated archive contains standard root-relative filesystem targets alongside an embedded `_sysinfo/` metadata directory capturing full operational state:

```
archive.tar.gz (or .tar.xz)
├── etc/                          # System configurations, PF rules, credentials
├── root/                         # Root user home directory
├── home/                         # User homes (profile-dependent)
├── usr/local/bin/, sbin/         # User and administrative scripts
├── var/cron/tabs/                # Scheduled cron jobs
├── var/backups/                  # System backup files
├── var/unbound/, named/, nsd/    # DNS chroots (server/vps profile)
├── var/www/                      # Optional web server root (-w / -a)
└── _sysinfo/                     # Embedded Bare-Metal & State Metadata
    ├── backup_manifest.txt       # Hostname, profile, timestamp, OS kernel, architecture
    ├── hardware_type.txt         # Hardware vendor, product, CPU, RAM, virtualization status
    ├── quick-restore.sh          # Self-contained emergency restoration helper
    ├── installed_packages.txt    # pkg_info -mz (exact manual package list)
    ├── installed_packages_full.txt # Complete pkg_info output with versions
    ├── services_enabled_rcctl.txt # Output of rcctl ls on
    ├── services_manual_rcctl.txt  # Output of rcctl ls manual
    ├── services_all_flags.txt     # Output of rcctl get --all (daemon flags & parameters)
    ├── rc.conf.local             # Live daemon overrides and flags
    ├── duids.txt                 # hw.disknames and /etc/fstab mappings
    ├── mounts.txt, swap.txt      # Live mount options (mount -v) and swapctl -l
    ├── disklabel_<disk>.txt      # Slice layouts for all active drives (compatible with disklabel -R)
    ├── fdisk_<disk>.txt          # MBR / GPT geometries for all active drives
    ├── bioctl_status.txt         # Softraid crypto & hardware RAID status
    ├── softraid_recreate.txt     # 1-line bioctl commands to recreate encrypted volumes
    ├── sensors.txt               # Hardware thermals, fan speeds, power supplies, battery wear
    ├── boot.conf, ttys           # Bootloader options (serial console) and getty configs
    ├── pf_rules.txt              # Active PF packet filter & NAT rules (pfctl -sr, -sn)
    ├── firmware_status.txt       # fw_update -n driver status
    ├── sysctl.txt, dmesg.txt     # Complete system parameters and boot dmesg
    ├── ifconfig.txt, routing_table.txt # Network interface & routing state
    ├── netstat_interfaces.txt, routing_table_detailed.txt # Detailed interface & routing metrics
    ├── arp_table.txt, ndp_table.txt    # ARP and IPv6 neighbor discovery tables
    ├── wsconsctl_state.txt       # Keyboard encoding, repeat rates, mouse controls (desktop/laptop)
    ├── mixerctl_state.txt        # Audio levels and DAC mixer controls (desktop/laptop)
    ├── audioctl_state.txt        # Audio driver state (desktop/laptop)
    ├── xrandr_modes.txt          # Display resolutions and monitor topology (desktop/laptop)
    ├── apm_status.txt            # Power management, AC status, battery percentage (laptop)
    ├── laptop_lid_power.txt      # Lid suspension, lid action, and CPU frequency scaling (laptop)
    ├── touchpad_state.txt        # Touchpad tapping, scaling, and reverse scrolling (laptop)
    ├── wireless_interfaces.txt   # Wireless interface link status, SSID, capabilities (laptop)
    ├── cloud_metadata.txt        # Cloud provider hints, VirtIO devices, cloud-init (VPS)
    └── *.sql.gz                  # Compressed MariaDB / PostgreSQL database dumps
```

---

## Profiles & Auto-Detection

[`backup.ksh`](backup.ksh) features intelligent multi-factor hardware auto-detection, or accepts an explicit `-p / --profile` flag:

### Auto-Detection Hierarchy (when `-p` is omitted)
1. **Laptop:** Detected when battery subsystem or battery sensor is active (`apm`, `sysctl hw.sensors` battery/acpibat), or recognized notebook chassis.
2. **Desktop:** Detected when graphical display subsystem is active (`$DISPLAY`, `xenodm`, `Xorg`, `wayland`) and machine is not a laptop.
3. **Cloud VPS:** Detected when hypervisor is detected (QEMU, KVM, VirtualBox, VMware, Xen, AWS EC2, DigitalOcean, Vultr, Hetzner, OpenBSD VMM, or VirtIO block/net devices) and machine is headless.
4. **Bare-metal Server:** Detected on physical bare-metal hardware without battery or graphical display.

### Profiles Overview

| Profile | Aliases | Typical Machine Target | Key Targets & Features | Exclusions & Safeguards |
| :--- | :--- | :--- | :--- | :--- |
| **`server`** | `baremetal`, `bare-metal` | Bare-Metal Servers, Routers, Firewalls | `/etc`, `/root`, `/home`, mail spools (`/var/mail`, `/var/spool/smtpd`, `/var/vmail`), DNS chroots (`unbound`, `named`, `nsd`), WireGuard keys (`/etc/wireguard`), cron tabs, optional web root (`/var/www` via `-w`), compressed database dumps (`-m`, `--postgres`), hardware RAID / `bioctl`, sensors, CARP / trunk networking, PF rules. | Full `/home` without desktop GUI state. Captures complete multi-disk layout and RAID state. |
| **`desktop`** | `workstation` | Workstations & Tower PCs | `/etc`, `/root`, `/home`, `/usr/local/bin`, `/usr/local/sbin`, `/var/cron/tabs`, `/usr/local/share/fonts`, multi-monitor topology (`xrandr`), audio (`mixerctl`, `audioctl`), console/keyboard (`wsconsctl`). | Smart cache exclusions: browser caches (Firefox, Chrome, Chromium), Trash, dev caches (Cargo, Node, Python, Pytest), and `~/Downloads` (toggle with `-D`). Desktop completion alerts (`-n`). |
| **`laptop`** | `notebook` | Laptops & Mobile Notebooks | All `desktop` targets + APM power management (`apmd`, power scripts in `/etc/apm/*`), touchpad tuning (`wsconsctl mouse`), wireless configurations (`/etc/hostname.<wifi-if>`), display backlight, CPU frequency scaling. | Pre-flight battery check (≤ 20% warning; aborts if critically low unless `-f/--force`). Same smart cache exclusions as desktop. Desktop completion alerts (`-n`). |
| **`vps`** | `cloud`, `vm` | Cloud Virtual Private Servers & VMs | `/etc`, `/root`, `/home`, cloud-init (`/etc/cloud`), autoinstall (`/etc/install.conf`), VirtIO block/net devices, serial console config (`boot.conf` `set tty com0`, `ttys`), SSH host keys, DHCP leases, optional `/var/www` and databases. | Smart scratch fallback to `/var/tmp` if `/tmp` is small. Automatic memory bounding (`XZ_OPT="-T1 -M 256M"`) on low-RAM VPS (≤ 1GB). |
| **`config`** | `dotfiles` | Dotfile Sync / Fast Config Recovery | `/etc`, `/root`, personal scripts in `~/bin` & `~/.local/bin`, dotfiles across all `/home/*` (e.g., `.config`, `.ssh`, `.gnupg`, `.password-store`, shell/editor/WM configs), and package/service lists. | Ultra-lightweight and fast (<20MB). Skips media, bulk downloads, and heavy documents entirely. Ideal for rapid offsite sync. |

---

## Prerequisites & Installation

### Requirements

- **Operating System:** OpenBSD 7.x or later (native `/bin/ksh`).
- **Privileges:** Root access (typically via `doas`).
- **Optional Dependencies:**
  - `xz` – for XZ compression (`-J` / `--xz`).
  - `mariadb-server` – for MariaDB database dumps (`-m` / `--mariadb`).
  - `postgresql-server` – for PostgreSQL dumps (`--postgres`).
  - `libnotify` (`notify-send`) or `xmessage` – for desktop completion notifications (`-n` / `--notify`).

### Configuring `doas`

Ensure your non-root user can run the utilities via `doas`. In `/etc/doas.conf`:

```text
# Permit wheel group members to execute commands as root
permit persist keepenv :wheel
```
> [!TIP]
> The `keepenv` directive preserves environment variables such as `DISPLAY` and `XAUTHORITY` when triggering desktop notifications or capturing `xrandr` display topologies.

### Installation

Install the scripts into standard OpenBSD system binary paths:

```bash
doas install -o root -g bin -m 755 backup.ksh /usr/local/sbin/backup.ksh
doas install -o root -g bin -m 755 restore.ksh /usr/local/bin/restore.ksh
```

---

## Quick Start

### 1. Creating Backups (`backup.ksh`)

```bash
# Auto-detects profile and hardware (bare-metal server, desktop, laptop, or VPS):
doas backup.ksh

# Bare-metal Server backup with /var/www, MariaDB, and PostgreSQL dumps:
doas backup.ksh -p server -w -m --postgres

# Laptop / Mobile Notebook backup (includes battery check, Wi-Fi configs, GUI alerts):
doas backup.ksh -p laptop -n

# Desktop Workstation backup (filters browser/build caches, captures xrandr/audio):
doas backup.ksh -p desktop -n

# Cloud VPS / Virtual Machine backup with offsite SCP transfer:
doas backup.ksh -p vps -w -u backupuser@nas.lan:/storage/vps-backups/

# Ultra-Fast Config & Dotfiles Backup (fast sync, <20MB):
doas backup.ksh -p config

# Automated Backup keeping only the 7 most recent archives (prunes older backups):
doas backup.ksh -k 7

# High-compression XZ archive saved to an external mount (memory-bounded on VPS):
doas backup.ksh -J -d /mnt/usbdrive
```

### 2. Inspecting & Restoring (`restore.ksh`)

`restore.ksh` supports safe read-only operations without root privileges, while system modification operations require `doas`:

```bash
# 1. Inspect archive metadata, hardware type, DUIDs, packages, and daemons (no root needed):
restore.ksh --show-info hostname_server_backup_2026.09.05-12.00.00.tar.gz

# 2. Verify archive SHA256 checksum and tar integrity:
restore.ksh --verify hostname_server_backup_2026.09.05-12.00.00.tar.gz

# 3. Diff archive files against the live filesystem before applying changes:
restore.ksh --diff hostname_server_backup_2026.09.05-12.00.00.tar.gz /etc

# 4. Search or list contents within the archive:
restore.ksh --list hostname_server_backup_2026.09.05-12.00.00.tar.gz pf.conf

# 5. Simulate a restore without touching the filesystem (Dry-Run):
restore.ksh --config-only --dry-run hostname_server_backup_2026.09.05-12.00.00.tar.gz

# 6. Restore only /etc, /root, and user dotfiles:
doas restore.ksh --config-only hostname_server_backup_2026.09.05-12.00.00.tar.gz

# 7. Extract archive into a staging or chroot directory:
doas restore.ksh --full --dest /mnt/staging hostname_server_backup_2026.09.05-12.00.00.tar.gz

# 8. Complete bare-metal turnkey restore (files + packages + services + firmware):
doas restore.ksh --all hostname_server_backup_2026.09.05-12.00.00.tar.gz
```

---

## Privilege & Permissions Matrix

To adhere to the principle of least privilege, `restore.ksh` allows read-only and inspection operations without root access, while system-altering operations strictly enforce `doas`/root requirements:

| Tool | Mode / Flag | Description | Requires Root (`doas`) |
| :--- | :--- | :--- | :---: |
| `backup.ksh` | *(all)* | System configuration & hardware state capture | **Yes** *(reads `/etc/master.passwd`, raw disk devices)* |
| `restore.ksh` | `-i, --show-info` | Inspect archive manifest, packages, services, DUIDs | **No** |
| `restore.ksh` | `-c, --verify` | Verify SHA256 checksum and tar integrity | **No** |
| `restore.ksh` | `-d, --diff` | Diff archive files against live system | **No** *(unless inspecting root-only files)* |
| `restore.ksh` | `-l, --list` | List or search contents within archive | **No** |
| `restore.ksh` | `-C, --config-only` | Restore `/etc`, `/root`, and user dotfiles | **Yes** |
| `restore.ksh` | `-F, --full` | Full extraction of archive to target filesystem | **Yes** |
| `restore.ksh` | `-p, --install-pkgs`| Reinstall recorded packages via `pkg_add -l` | **Yes** |
| `restore.ksh` | `-s, --enable-services` | Re-enable daemons via `rcctl` | **Yes** |
| `restore.ksh` | `-a, --all` | Complete turnkey bare-metal rebuild | **Yes** |
| `quick-restore.sh` | *(embedded)* | Standalone rescue helper in `_sysinfo/` | **Yes** |

---

## Complete Command Reference

### `backup.ksh`

```
Usage: backup.ksh [OPTIONS]

Unified OpenBSD Backup Utility

Profiles:
  -p, --profile PROFILE     Select profile: server (or baremetal), desktop, laptop,
                            vps (or cloud), or config (default: auto-detected)
                            - server : Bare-metal server (RAID/bioctl, sensors, CARP/trunk,
                                       daemon chroots, optional /var/www and DB dumps).
                            - desktop: Desktop workstation (/etc, dotfiles, /home, fonts,
                                       display/audio/wsconsctl, cache exclusions).
                            - laptop : Laptop/notebook (desktop features + battery safety check,
                                       touchpad, APM power management, wireless configs).
                            - vps    : Cloud VPS & VMs (VirtIO storage/networking, cloud-init,
                                       serial console, low-scratch & RAM-aware compression).
                            - config : Fast backup of /etc, dotfiles, scripts, package lists.

Target & Destination:
  -d, --dest DIR            Destination directory for the archive (default: user home or /root)
  -o, --output FILE         Explicit output filepath for the archive
  -t, --temp-dir DIR        Temporary scratch directory (default: $TMPDIR, /var/tmp, or /tmp)
  -u, --upload DEST         Upload archive and sha256 to remote host via scp (user@host:/path)
  -k, --keep COUNT          Retain only COUNT most recent backups in dest dir, pruning older ones

Options & Exclusions:
  -f, --force               Bypass safety checks (battery warnings, scratch space alerts)
  -J, --xz                  Use XZ compression (.tar.xz) instead of gzip (.tar.gz)
  -w, --web                 Include /var/www (useful for server/vps web servers)
  -m, --mariadb             Include MariaDB/MySQL database dump
      --postgres            Include PostgreSQL database dump (via pg_dumpall)
  -a, --all                 Include both web data and MariaDB database dump
  -D, --include-downloads   Include ~/Downloads directory (excluded by default on desktop/laptop)
  -C, --include-caches      Include browser and build caches (excluded by default)
  -N, --no-excludes         Disable all built-in exclusion rules
  -x, --exclude PATTERN     Add custom tar exclusion pattern (repeatable)
      --exclude-file FILE   Read newline-delimited exclusion patterns from FILE
  -n, --notify              Send desktop notification on completion (desktop/laptop profile)
  -v, --verbose             Enable verbose output during tar archiving
  -h, --help                Display this help message and exit
```

### `restore.ksh`

```
Usage: restore.ksh <MODE> [OPTIONS] <ARCHIVE> [PATH]

OpenBSD Disaster Recovery & Rapid Restoration Utility

Modes (select one):
  -i, --show-info ARCHIVE      Inspect and display backup metadata (manifest, DUIDs,
                               package counts, enabled services, hardware state)
  -c, --verify ARCHIVE         Verify archive SHA256 checksum and tar integrity
  -d, --diff ARCHIVE [PATH]    Diff archive files against live system before restoring
                               (default PATH: /etc, or specify e.g. /etc/pf.conf)
  -l, --list ARCHIVE [PAT]     List files inside the archive (optional grep pattern)
  -C, --config-only ARCHIVE    Fast restoration of /etc and user dotfiles only
  -F, --full ARCHIVE           Full extraction of all files in archive to root (/)
  -p, --install-pkgs ARCHIVE   Reinstall all packages recorded at backup time
  -s, --enable-services ARCH   Re-enable all daemons recorded in services list
  -a, --all ARCHIVE            Complete bare-metal restore (full extract + pkgs + services)

Options:
  --dest DIR                   Target restore directory (default: /)
  -n, --dry-run                Simulate restoration actions without modifying system
  -v, --verbose                Enable verbose extraction output
  -h, --help                   Display this help message and exit
```

---

## Exclusion Rules & Custom Filtering

### Built-in Loop, Socket & Recursion Protection (Always Active)
OpenBSD's native `tar(1)` (based on `pax(1)`) does not support GNU `--exclude` options. `backup.ksh` natively implements exclusions using OpenBSD `tar -s replstr` pattern substitution rules (`-s ',pattern,,'`), where paths that substitute to the empty string are not archived.

To prevent accidental recursion, exponential archive expansion, socket errors, and corrupted backup data, `backup.ksh` strictly enforces these exclusions on every run across all profiles:
- **Prior Backup Archives:** `.*_backup_.*\.tar\..*`, `.*\.tar\.gz$`, `.*\.tar\.xz$`, `.*\.tgz$`
- **Integrity Checksums:** `.*_backup_.*\.sha256`, `.*\.sha256$`
- **Temporary Staging Files:** `.*/\..*\.tmp\..*`, `.*\.tmp\.[0-9]*`
- **UNIX Domain Sockets:** `.*\.gnupg/S\..*`, `.*\.sock$`, `.*\.socket$` (OpenBSD `ustar` format cannot archive dynamic IPC sockets)
- **Target Destination Files:** Automatically excludes destination archives and companion checksums when writing inside backed-up directories (e.g., `/var/backups`, `/home`, `/root`)
- **Foreign & Network Mounts:** Automatically parses active mount points to exclude foreign filesystems (`nfs`, `fuse`/sshfs, `mfs`) mounted under target directories

### Default Cache & Ephemeral Exclusions
In addition to loop safeguards, the `desktop` and `laptop` profiles skip ephemeral caches, build artifacts, and downloads (disable with `-N / --no-excludes` or include caches with `-C / --include-caches`):
- **User Caches:** `~/.cache`, `~/.thumbnails`, `~/.local/share/Trash`
- **Browser Profiles & Electron:** Firefox (`cache2`, `storage`), Chromium / Chrome / Electron cache directories (`Code Cache`, `GPUCache`)
- **Development & Build Caches:**
  - Cargo / Rust: `~/.cargo/registry`, `~/.cargo/git`, `target/debug`, `target/release`
  - Go: `~/go/pkg/mod/cache`
  - Java: `~/.gradle/caches`, `~/.m2/repository`
  - Node: `node_modules`
  - Python: `__pycache__`, `.pytest_cache`, `.venv`, `venv`
- **Transient Files:** `*.core`, `*.swp`
- **Downloads:** `~/Downloads` (excluded on `desktop` and `laptop`; bypass with `-D`)

### Custom Exclusions
You can append custom exclusion patterns at runtime using standard intuitive syntax. `backup.ksh` automatically normalizes and converts user globs, directory paths, and file extensions into native OpenBSD `tar -s` regular expression rules:

```bash
# Add inline exclusions:
doas backup.ksh -x "*/VirtualBox VMs" -x "*.iso"

# Read exclusions from an external pattern file:
doas backup.ksh --exclude-file /etc/backup-excludes.txt
```
*(Lines beginning with `#` and blank lines in exclusion files are automatically ignored).*

---

## Disaster Recovery Guides by Environment

### 1. Bare-Metal Physical Servers
When rebuilding a physical server with hardware RAID or softraid crypto volumes:
1. **Review Storage Geometry:** Run `restore.ksh --show-info backup.tar.gz` and review `bioctl_status.txt`, `softraid_recreate.txt`, `disklabel_*.txt`, and `fdisk_*.txt`.
2. **Re-create Volumes:** Initialize hardware RAID or reassemble the softraid crypto container using the commands saved in `softraid_recreate.txt` (e.g., `bioctl -c C -l <chunk_duid>.a softraid0`).
3. **Restore Disklabel Slices:** Restore disk partition tables onto replacement drives using `disklabel -R <disk> _sysinfo/disklabel_<disk>.txt`.
4. **Fresh Base Install:** Install standard OpenBSD base sets onto the new volume or partitions.
5. **Turnkey Restore:** Run `doas restore.ksh --all backup.tar.gz` to reinstall all packages, re-enable services, and restore configuration files.
6. **Verify HA & Network:** Review `/etc/hostname.*` (CARP, trunk, VLAN interfaces) and `/etc/pf.conf` before rebooting.

### 2. Laptops & Mobile Notebooks
When restoring onto a new laptop drive or replacement machine:
1. **Fresh Base Install:** Install standard OpenBSD base sets.
2. **Turnkey Restore:** Run `doas restore.ksh --all backup.tar.gz`.
3. **Verify Wi-Fi & Touchpad:**
   - Confirm wireless network credentials in `/etc/hostname.<wifi-if>`.
   - Verify touchpad tapping and scrolling settings in `/etc/wsconsctl.conf`.
   - Ensure power daemon is enabled: `rcctl enable apmd && rcctl set apmd flags -A`.

### 3. Cloud VPS & Virtual Machines
When recovering onto a newly deployed VPS instance (AWS, Vultr, DigitalOcean, Hetzner, etc.):
1. **Deploy Minimal Instance:** Spin up a new OpenBSD instance or boot into recovery.
2. **Turnkey Restore:** Transfer the archive and run `doas restore.ksh --all backup.tar.gz`.
3. **Verify Serial Console & SSH:**
   - Confirm `/etc/boot.conf` retains `set tty com0` (required for cloud web consoles).
   - Ensure SSH host keys (`/etc/ssh/ssh_host_*_key*`) and `/root/.ssh/authorized_keys` are intact before terminating the active session.
   - Verify VirtIO interface configuration in `/etc/hostname.vio0`.

### 4. Restoring Database Dumps
When recovering a system that hosted databases, restore database dumps after base recovery, package installation, and service configuration are complete:

#### MariaDB / MySQL
```bash
# 1. Start the MariaDB daemon:
doas rcctl start mysqld

# 2. Restore all databases from the compressed SQL dump:
gunzip -c _sysinfo/mariadb_all_databases.sql.gz | mysql -u root -p
```

#### PostgreSQL
```bash
# 1. Initialize PostgreSQL cluster (if restoring onto a completely new disk):
doas su -l _postgresql -c "initdb -D /var/postgresql/data -U postgres -A scram-sha-256 -E UTF8"

# 2. Start the PostgreSQL daemon:
doas rcctl start postgresql

# 3. Restore all databases from the compressed SQL dump:
gunzip -c _sysinfo/postgresql_all_databases.sql.gz | doas su -l _postgresql -c psql
```

---

## Autonomous Emergency Recovery (`quick-restore.sh`)

If you find yourself on a recovery console or live environment without `restore.ksh`, you can leverage the autonomous rescue helper embedded inside every archive:

```bash
# 1. Extract only the embedded _sysinfo metadata folder:
tar -xzpf backup.tar.gz _sysinfo

# 2. Run the embedded rescue helper:
sh _sysinfo/quick-restore.sh
```

This helper will print the backup manifest, hardware classification, display exact commands to restore packages, re-enable services, run `fw_update`, and provide profile-tailored post-restoration guidance.

---

## Automated Scheduling with `cron`

Configure automated recurring backups by editing root's crontab (`doas crontab -e`):

```crontab
# Bare-metal physical server: daily backup at 03:00 AM with /var/www, DB dumps, and SCP upload:
0 3 * * * /usr/local/sbin/backup.ksh -p server -w -m --postgres -k 7 -d /var/backups -u backupuser@nas.lan:/storage/backups/ >/dev/null 2>&1

# Cloud VPS: daily backup at 02:30 AM with 7-day retention pushed offsite via SCP:
30 2 * * * /usr/local/sbin/backup.ksh -p vps -w -k 7 -d /var/backups -u backupuser@nas.lan:/storage/vps-backups/ >/dev/null 2>&1

# Laptop / Notebook: daily backup at 12:00 PM with GUI notification:
0 12 * * * /usr/local/sbin/backup.ksh -p laptop -k 7 -d /var/backups -n >/dev/null 2>&1

# Workstation Desktop: daily backup at 02:00 AM with GUI notification:
0 2 * * * /usr/local/sbin/backup.ksh -p desktop -k 14 -d /var/backups -n >/dev/null 2>&1

# Hourly lightweight configuration & dotfiles backup:
0 * * * * /usr/local/sbin/backup.ksh -p config -k 24 -d /var/backups/config >/dev/null 2>&1
```

---

## Testing & Verification

An automated verification test suite is provided in [`tests/test_runner.sh`](tests/test_runner.sh). It validates shell syntax across `/bin/ksh` and `/bin/sh`, argument parsing, profile normalization/aliases, environment auto-detection heuristics against mocked platforms (bare-metal physical servers, desktop workstations, ThinkPad laptops, and QEMU/Vultr cloud VMs), native OpenBSD `tar -s` regex exclusions and live UNIX domain socket handling, and end-to-end archive verification and metadata inspection via [`restore.ksh`](restore.ksh).

To run the test suite:

```bash
sh tests/test_runner.sh
```

---

## License

ISC License. Copyright (c) 2026 Marcus Swenson <src@marcusswenson.com>.

See [LICENSE](LICENSE) for the complete license text.
