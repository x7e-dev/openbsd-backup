# OpenBSD Unified Backup & Rapid Disaster Recovery

A robust, profile-driven backup and bare-metal disaster recovery toolkit engineered specifically for OpenBSD. Written in pure OpenBSD Korn Shell (`/bin/ksh`), it captures system configurations, user dotfiles, running services, database dumps, and complete hardware/storage geometries for deterministic, rapid restoration.

Engineered with specialized support for:
- **Bare-metal Physical Servers & Raspberry Pi / ARM SBCs:** Hardware RAID controllers, softraid crypto volumes (`softraid0`), environmental sensors, bonded network interfaces (`trunk`/`aggr`/`carp`), PF firewall rules/tables/anchors, daemon chroots, Raspberry Pi MSDOS boot partition (`config.txt`/`cmdline.txt`), and databases (MariaDB, PostgreSQL, SQLite).
- **Workstation Desktops:** Multi-monitor topologies (`xrandr`), audio controls (`sndioctl`/`mixerctl`/`audioctl`), console mappings (`wsconsctl`), desktop fonts, and smart cache exclusions (preserving Firefox extension data).
- **Laptops & Mobile Notebooks:** Battery health checks, APM power management (`apmd`), touchpad tapping/scrolling tuning, display backlight, and wireless network configurations.
- **Cloud VPS & Virtual Machines:** VirtIO storage/networking (`vioblk`/`vio`), cloud-init / autoinstall configs, serial console redirection (`boot.conf` `set tty com0`), memory-conscious compression (`zstd` / RAM-bounded `xz`), `age` encryption at rest, and low-disk scratch awareness.
- **Rapid Config Sync:** Lightweight dotfile and `/etc` sync (<20MB) across any environment.
- **macOS Companion Inspection:** Read-only inspection, verification, and decryption (`restore.ksh --verify`, `--show-info`, `--list`) also run natively on macOS (`/bin/ksh`).

---

## Table of Contents

- [Key Highlights](#key-highlights)
- [Architecture & Archive Anatomy](#architecture--archive-anatomy)
- [Profiles & Auto-Detection](#profiles--auto-detection)
- [Prerequisites & Installation](#prerequisites--installation)
- [Quick Start](#quick-start)
  - [1. Creating Backups (`backup.ksh`)](#1-creating-backups-backupksh)
  - [2. Inspecting & Restoring (`restore.ksh`)](#2-inspecting--restoring-restoreksh)
- [Security, Signing & Secrets Hardening](#security-signing--secrets-hardening)
  - [Encryption at Rest with `age(1)`](#encryption-at-rest-with-age1)
  - [OpenBSD signify(1) Cryptographic Signatures](#openbsd-signify1-cryptographic-signatures)
  - [Secrets Isolation (`--skip-secrets`)](#secrets-isolation---skip-secrets)
  - [Ownership Model & Privilege Containment (`--chown`)](#ownership-model--privilege-containment---chown)
  - [Live Restoration Guardrails & Safety Snapshots](#live-restoration-guardrails--safety-snapshots)
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
- **Turnkey Disaster Recovery:** A dedicated restoration engine ([`restore.ksh`](restore.ksh)) featuring SHA256 verification, pre-apply unified diffing (`--diff`), dry-run simulations (`--dry-run`), resilient non-fatal warning tolerance, and full bare-metal rebuilding (`--all`) with backward-compatible support for legacy archive metadata.
- **Autonomous Emergency Helper:** Every archive embeds an executable `_sysinfo/quick-restore.sh` helper, enabling guided disaster recovery even if `restore.ksh` is not present on the rescue media.
- **Bare-Metal Storage & Hardware Metadata:** Automatically preserves DUIDs, active mount points (`fstab`), per-disk `fdisk` geometries, `disklabel` slice allocations, encrypted softraid / hardware RAID (`bioctl`) volume mappings, sensors, and bootloader settings (`boot.conf`).
- **Form-Factor & Partition Safeguards:**
  - **Direct-to-Destination Staging:** Stages temporary archives directly in the target destination filesystem rather than `/tmp`, bypassing OpenBSD's small (500MB–1GB) `/tmp` slice and avoiding cross-device copy overhead.
  - **Root Slice Space Guard:** Automatically detects if the destination is on the root filesystem (`/`) and warns the user to prevent filling OpenBSD's typically small (1–2GB) `/` slice.
  - **Strict Recursion & Loop Prevention:** Always excludes prior backup archives (`*_backup_*.tar.*`, `*_backup_*.sha256*`, `*_backup_*.sig`), temporary staging files, and anchored foreign/network mountpoints (`nfs`, `fuse`, `fusefs`/sshfs, `mfs`, `tmpfs`, `smbfs`) without dropping personal `.tar.gz`/`.tar.xz`/`.tgz` archives or unrelated `*/tmp/*` directories.
  - **Native OpenBSD tar(1) Compatibility:** Leverages OpenBSD `tar(1)` / `pax(1)` native `-s replstr` exclusions (`-s ',pattern,,'`) and pipes compression through `gzip`/`xz`/`zstd` (avoiding unsupported OpenBSD `tar -J`), guaranteeing 100% base OpenBSD compatibility without external `gtar`.
  - **UNIX Domain Socket Exclusions:** Proactively skips active IPC sockets (`.gnupg/S.*`, `*.sock`, `*.socket`), while strictly failing on real `tar` read/I/O/permission errors.
  - **Laptop Battery Protection:** Pre-flight battery check warns or prevents running heavy compression operations on low battery (≤ 20%) to avoid sudden shutdown.
  - **Zstandard & Adaptive RAM-Bounded XZ Compression:** Supports fast, low-memory Zstandard (`-Z / --zstd`, ideal for Raspberry Pi and VPS) alongside piped XZ (`-J / --xz`) with 3-tier RAM caps (`<= 1GB`: `-T1 -M 256M`, `<= 4GB`: `-T2 -M 40%`, `> 4GB`: `-T0 -M 50%`) to prevent OOM and OpenBSD `login.conf` `datasize` failures.
- **Hardened Security by Default:**
  - Enforces `umask 077` throughout both `backup.ksh` and `restore.ksh` (`0600` archive / `0700` working directories), guaranteeing sensitive data (such as `/etc/master.passwd`, SSH host keys, WireGuard keys, and database dumps) is never world-readable.
  - **Encryption at Rest (`age`):** Optional public-key streaming encryption (`-e / --encrypt-key` or auto-detected `/etc/age/backup.pub`) pipes compressed tar output directly through `age(1)` so plaintext archives never touch disk and compromised hosts cannot decrypt previous backups.
  - **Cryptographic Signatures (`signify`):** Signs the archive's BSD-tagged `.sha256` manifest (`signify -S -e` → `.sha256.sig`) and verifies via `signify -C` (fail-closed), completely avoiding `signify`'s 1 GiB file-size limit and high RAM usage on multi-GB archives.
  - **Secrets Isolation (`--skip-secrets`):** Excludes password hashes, `/var/backups` shadow copies, `/etc/signify/*.sec`, `/etc/hostname.*` (`wpakey`/`wgkey`), `/etc/acme/*`, `/etc/iked/private/*`, `/etc/mail/secrets`, SSH private keys (while preserving `id_*.pub` and host `.pub` keys), `.netrc`, `.aws`, shell histories, session cookies, and DB dumps, and redacts `wgkey`/`wpakey` in `_sysinfo/ifconfig.txt`.
  - **Strict Archive Ownership:** Backups containing system secrets retain `root:wheel` (`0600`) ownership to prevent privilege leakage to non-root users (`--chown` permits transfer when secrets are excluded).
  - **Live Restoration Guardrails:** `restore.ksh` protects live `/etc/fstab` by default (preserving disk DUIDs and saving the backup's copy to `/var/backups/fstab.from-backup`), warns on OpenBSD release mismatches, rebuilds `/etc/pwd.db` via `pwd_mkdb -p /etc/master.passwd`, skips `/etc/passwd` when restoring `--skip-secrets` archives, captures a `/var/backups/etc.pre-restore.<timestamp>.tar.gz` snapshot, and uses anchored `_sysinfo` exclusions.
- **Production-Grade Reliability:**
  - Pipeline termination safety (`set -o pipefail`) plus separate `tar` and compressor/encryptor exit checks so I/O errors, failed DB dumps, and failed uploads exit non-zero and log to `syslog` (`logger -t openbsd-backup`).
  - Quiet mode (`-q / --quiet`) for clean `cron(8)` runs that email `root` only on warnings or errors.
  - File locking (`/var/run/openbsd-backup.lock`) with active PID and orphaned-lock recovery.
  - Pre-flight storage checks (`df -k`) on scratch and target directories with fail-safe aborts to prevent filesystem exhaustion.
  - Streaming database compression (`.sql.gz`) for MariaDB/PostgreSQL plus safe live SQLite snapshots (`--sqlite`).
  - Single-pass `--config-only` restoration using OpenBSD `tar -I` (or macOS `tar -T`).
  - True atomic archive deployment (same-filesystem instantaneous rename).
  - Automated retention pruning (`--keep N`) across `.tar.gz`, `.tar.xz`, `.tar.zst`, and `.age` archives, cleaning companion `.sha256`, `.sha256.sig`, and `.sig` files.
  - Offsite SCP upload with `BatchMode=yes`, `ConnectTimeout=30`, optional `--ssh-key`, and root-safe permission handling.

---

## Architecture & Archive Anatomy

Each generated archive contains standard root-relative filesystem targets alongside an embedded `_sysinfo/` metadata directory capturing full operational state (with [`restore.ksh`](restore.ksh) providing seamless backward compatibility for older archives using legacy `openbsd_sysinfo.XXXXXXXXXX` metadata folders):

```
archive.tar.gz (or .tar.xz / .tar.zst / .age)
├── etc/                          # System configurations, PF rules, credentials
├── root/                         # Root user home directory
├── home/                         # User homes (profile-dependent)
├── usr/local/bin/, sbin/         # User and administrative scripts
├── var/cron/tabs/                # Scheduled cron jobs
├── var/unbound/, named/, nsd/    # DNS chroots (server/vps profile)
├── var/www/                      # Optional web server root (-w / -a)
└── _sysinfo/                     # Embedded Bare-Metal & State Metadata
    ├── backup_manifest.txt       # Hostname, profile, timestamp, OS release, compression, encryption
    ├── hardware_type.txt         # Hardware vendor, product, CPU, RAM, virtualization status
    ├── quick-restore.sh          # Self-contained emergency restoration helper
    ├── installed_packages.txt    # pkg_info -mz (exact manual package list)
    ├── installed_packages_full.txt # Complete pkg_info output with versions
    ├── services_enabled_rcctl.txt # Output of rcctl ls on
    ├── services_started_rcctl.txt # Output of rcctl ls started
    ├── services_all_flags.txt     # Output of rcctl get all (daemon flags & parameters)
    ├── rc.conf.local             # Live daemon overrides and flags
    ├── duids.txt                 # hw.disknames and /etc/fstab mappings
    ├── mounts.txt, swap.txt      # Live mount options (mount -v) and swapctl -l
    ├── disklabel_<disk>.txt      # Slice layouts for all active drives (compatible with disklabel -R)
    ├── fdisk_<disk>.txt          # MBR / GPT geometries for all active drives
    ├── rpi_boot/                 # Raspberry Pi / ARM MSDOS boot partition (config.txt, cmdline.txt)
    ├── bioctl_status.txt         # Softraid (softraid0) & hardware RAID status
    ├── softraid_recreate.txt     # bioctl commands to recreate encrypted volumes
    ├── sensors.txt               # Hardware thermals, fan speeds, power supplies, battery wear
    ├── boot.conf, ttys           # Bootloader options (serial console) and getty configs
    ├── pf_rules.txt              # Active PF rules, tables, and anchors (pfctl -sr, -s Tables/Anchors)
    ├── firmware_status.txt       # fw_update -n driver status
    ├── sysctl.txt, dmesg.txt     # Complete system parameters and boot dmesg
    ├── ifconfig.txt, routing_table.txt # Network interface (redacted under --skip-secrets) & routing state
    ├── netstat_interfaces.txt, routing_table_detailed.txt # Detailed interface & routing metrics
    ├── arp_table.txt, ndp_table.txt    # ARP and IPv6 neighbor discovery tables
    ├── wsconsctl_state.txt       # Keyboard encoding, repeat rates, mouse controls (desktop/laptop)
    ├── sndioctl_state.txt        # Audio device/volume state via sndioctl(1) (desktop/laptop)
    ├── mixerctl_state.txt        # Audio levels and DAC mixer controls (desktop/laptop)
    ├── audioctl_state.txt        # Audio driver state (desktop/laptop)
    ├── xrandr_modes.txt          # Display resolutions and monitor topology (desktop/laptop)
    ├── apm_status.txt            # Power management, AC status, battery percentage (laptop)
    ├── laptop_lid_power.txt      # Lid suspension, lid action, and CPU frequency scaling (laptop)
    ├── touchpad_state.txt        # Touchpad tapping, scaling, and reverse scrolling (laptop)
    ├── wireless_interfaces.txt   # Wireless interface link status, SSID, capabilities (laptop)
    ├── cloud_metadata.txt        # Cloud provider hints, VirtIO devices, cloud-init (VPS)
    ├── sqlite/                   # Safe live SQLite snapshots (--sqlite)
    └── *.sql.gz                  # Compressed MariaDB / PostgreSQL database dumps
```

---

## Profiles & Auto-Detection

[`backup.ksh`](backup.ksh) features intelligent multi-factor hardware auto-detection, or accepts an explicit `-p / --profile` flag:

### Auto-Detection Hierarchy (when `-p` is omitted)
1. **Laptop:** Detected when battery subsystem or battery sensor is active (`apm`, `sysctl hw.sensors` battery/acpibat), or recognized notebook chassis.
2. **Desktop:** Detected when graphical display subsystem is active (`$DISPLAY`, `xenodm`, `Xorg`, `wayland`) and machine is not a laptop.
3. **Cloud VPS:** Detected when hypervisor is detected (QEMU, KVM, VirtualBox, VMware, Xen, AWS EC2, DigitalOcean, Vultr, Hetzner, Google Compute Engine, Azure/Hyper-V, OpenBSD VMM, or VirtIO block/net devices) and machine is headless.
4. **Raspberry Pi / ARM SBC:** Detected via `hw.vendor`/`hw.product`/`hw.version` or `dmesg` (`bcm2711`, `bcm2837`, `bcm2712`); mapped to the `server` profile with automatic MSDOS boot partition (`config.txt`/`cmdline.txt`) capture.
5. **Bare-metal Server:** Detected on physical bare-metal hardware without battery or graphical display.

### Profiles Overview

| Profile | Aliases | Typical Machine Target | Key Targets & Features | Exclusions & Safeguards |
| :--- | :--- | :--- | :--- | :--- |
| **`server`** | `baremetal`, `bare-metal`, `rpi`, `raspberrypi`, `raspberry-pi` | Bare-Metal Servers, Routers, Firewalls, Raspberry Pi / ARM SBCs | `/etc`, `/root`, `/home`, mail spools (`/var/mail`, `/var/spool/smtpd`, `/var/vmail`), DNS chroots (`unbound`, `named`, `nsd`), DHCP leases (`/var/db/dhcpd`), cron/at jobs, optional web root (`/var/www` via `-w`), compressed database dumps (`-m`, `--postgres`, `--sqlite`), hardware RAID / `bioctl`, sensors, CARP / trunk networking, PF rules/tables/anchors, and RPi MSDOS boot partition (`config.txt`/`cmdline.txt`). | Full `/home` without desktop GUI state. Captures complete multi-disk layout and RAID state. |
| **`desktop`** | `workstation` | Workstations & Tower PCs | `/etc`, `/root`, `/home`, `/usr/local/bin`, `/usr/local/sbin`, `/var/cron/tabs`, `/usr/local/share/fonts`, multi-monitor topology (`xrandr`), audio (`sndioctl`, `mixerctl`, `audioctl`), console/keyboard (`wsconsctl`). | Smart cache exclusions: browser caches (Firefox caches while preserving `storage/default` extension data, Chrome, Chromium), Trash, dev caches (Cargo, Go, Gradle, Maven, Node, Python, Pytest), and `~/Downloads` (toggle with `-D`). Desktop completion alerts (`-n`). |
| **`laptop`** | `notebook` | Laptops & Mobile Notebooks | All `desktop` targets + APM power management (`apmd`, power scripts in `/etc/apm/*`), touchpad tuning (`wsconsctl mouse`), wireless configurations (`/etc/hostname.<wifi-if>`), display backlight, CPU frequency scaling. | Pre-flight battery check (≤ 20% warning; aborts if critically low unless `-f/--force`). Same smart cache exclusions as desktop. Desktop completion alerts (`-n`). |
| **`vps`** | `cloud`, `vm` | Cloud Virtual Private Servers & VMs | `/etc`, `/root`, `/home`, DNS chroots (`unbound`, `nsd`), cloud-init (`/etc/cloud`), autoinstall (`/etc/install.conf`), VirtIO block/net devices, serial console config (`boot.conf` `set tty com0`, `ttys`), SSH host keys, optional `/var/www` and databases. | Smart scratch fallback to `/var/tmp` if `/tmp` is small. Fast `zstd` (`-Z`), `age` encryption (`-e`), and 3-tier RAM-bounded XZ (`<= 1GB`: `-T1 -M 256M`, `<= 4GB`: `-T2 -M 40%`, `> 4GB`: `-T0 -M 50%`). |
| **`config`** | `dotfiles` | Dotfile Sync / Fast Config Recovery | `/etc`, `/root`, personal scripts in `~/bin` & `~/.local/bin`, dotfiles across all `/home/*` (e.g., `.config`, `.ssh`, `.gnupg`, `.password-store`, shell/editor/WM configs), and package/service lists. | Ultra-lightweight and fast (<20MB). Secrets stripped by default (`--skip-secrets`), chowned to calling user. Skips media, bulk downloads, and heavy documents entirely. |

---

## Prerequisites & Installation

### Requirements

- **Operating System:** OpenBSD 7.x or later (native `/bin/ksh`). Read-only inspection/verification via `restore.ksh` (`--verify`, `--show-info`, `--list`) also runs on macOS (`/bin/ksh`).
- **Privileges:** Root access (typically via `doas`) for `backup.ksh` and live system restores.
- **Optional Dependencies:**
  - `age` – for public-key encryption at rest (`-e` / `--encrypt-key`; `pkg_add age` / `brew install age`).
  - `zstd` – for fast Zstandard compression (`-Z` / `--zstd`; recommended for Raspberry Pi & VPS).
  - `xz` – for XZ compression (`-J` / `--xz`).
  - `mariadb-server` – for MariaDB database dumps (`-m` / `--mariadb`).
  - `postgresql-server` – for PostgreSQL dumps (`--postgres`).
  - `sqlite3` – for consistent live SQLite snapshots (`--sqlite`).
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

# Bare-metal Server / Raspberry Pi backup with /var/www, MariaDB, PostgreSQL, and SQLite snapshots:
doas backup.ksh -p server -w -m --postgres --sqlite /var/www/app.db

# Laptop / Mobile Notebook backup (includes battery check, Wi-Fi configs, GUI alerts):
doas backup.ksh -p laptop -n

# Desktop Workstation backup (filters browser/build caches, captures xrandr/sndioctl):
doas backup.ksh -p desktop -n

# Cloud VPS / Virtual Machine backup with zstd compression, age encryption, and offsite SCP:
doas backup.ksh -p vps -Z -e /etc/age/backup.pub -w --ssh-key /root/.ssh/id_backup -u backupuser@nas.lan:/storage/vps-backups/

# Ultra-Fast Config & Dotfiles Backup (fast sync, <20MB, secrets stripped by default):
doas backup.ksh -p config

# Cryptographically sign archive using OpenBSD signify(1):
doas backup.ksh -S /etc/signify/backup.sec

# Dotfiles & configuration backup stripped of secrets (safe for git/sharing, chowned to user):
doas backup.ksh -p config --skip-secrets --chown

# Automated Backup keeping only the 7 most recent archives (prunes older backups):
doas backup.ksh -k 7

# High-compression XZ archive saved to an external mount (RAM-bounded across 3 memory tiers):
doas backup.ksh -J -d /mnt/usbdrive
```

### 2. Inspecting & Restoring (`restore.ksh`)

`restore.ksh` supports safe read-only operations without root privileges, while system modification operations require `doas`:

```bash
# 1. Inspect archive metadata, hardware type, DUIDs, packages, and daemons (no root needed):
restore.ksh --show-info hostname_server_backup_2026.09.05-12.00.00.tar.gz

# 2. Verify archive SHA256 checksum, tar integrity, and signify signature:
restore.ksh --verify -S /etc/signify/backup.pub hostname_server_backup_2026.09.05-12.00.00.tar.gz

# 3. Diff archive files against the live filesystem before applying changes:
restore.ksh --diff hostname_server_backup_2026.09.05-12.00.00.tar.gz /etc

# 4. Search or list contents within the archive:
restore.ksh --list hostname_server_backup_2026.09.05-12.00.00.tar.gz pf.conf

# 5. Simulate a restore without touching the filesystem (Dry-Run):
restore.ksh --config-only --dry-run hostname_server_backup_2026.09.05-12.00.00.tar.gz

# 6. Restore only /etc, /root, user scripts, and dotfiles (prompts confirmation & saves /etc snapshot):
doas restore.ksh --config-only hostname_server_backup_2026.09.05-12.00.00.tar.gz

# 7. Extract archive into a staging or chroot directory:
doas restore.ksh --full --dest /mnt/staging hostname_server_backup_2026.09.05-12.00.00.tar.gz

# 8. Complete bare-metal turnkey restore (files + packages + services + firmware):
doas restore.ksh --all hostname_server_backup_2026.09.05-12.00.00.tar.gz

# 9. Non-interactive automated restore (bypasses prompt, verifies signature, preserves safety snapshot):
doas restore.ksh --config-only -f hostname_server_backup_2026.09.05-12.00.00.tar.gz
```

---

## Security, Signing & Secrets Hardening

The toolkit implements defense-in-depth security principles engineered specifically for production OpenBSD deployments.

### Encryption at Rest with `age(1)`
Signing (`signify`) proves authenticity and integrity, **not** confidentiality. When storing archives offsite (VPS → NAS/cloud, or USB drives), encrypt them at rest with `age(1)` so only the **public** key lives on the backed-up machine:

1. **Generate an `age` Keypair (keep the private key offline / on your trusted Mac):**
   ```bash
   age-keygen -o backup.age.key
   age-keygen -y backup.age.key > backup.pub
   ```
2. **Install ONLY the public key on your OpenBSD hosts (VPS, Raspberry Pi, Desktop):**
   ```bash
   doas mkdir -m 755 -p /etc/age
   doas cp backup.pub /etc/age/backup.pub
   ```
   `backup.ksh` automatically detects `/etc/age/backup.pub` (or accepts `-e / --encrypt-key FILE`) and streams compressed `tar` output directly through `age` so plaintext archives never touch disk. Pass `--no-encrypt` to disable auto-encryption for a run.
3. **Inspect, Verify, or Restore from macOS or OpenBSD:**
   ```bash
   # Verify signature + checksum without needing the decryption key:
   restore.ksh --verify -S /etc/signify/backup.pub host_vps_backup_2026.11.21.tar.zst.age

   # Inspect or decrypt with your offline private key:
   restore.ksh --show-info -K ~/backup.age.key host_vps_backup_2026.11.21.tar.zst.age
   doas restore.ksh --all -K /mnt/usb/backup.age.key host_vps_backup_2026.11.21.tar.zst.age
   ```

### OpenBSD signify(1) Cryptographic Signatures
OpenBSD's native `signify(1)` utility creates and verifies Ed25519 digital signatures. Because `signify(1)` enforces a 1 GiB max message size when signing raw files directly, `backup.ksh` follows OpenBSD's release-signing convention: it signs the tiny BSD-tagged `.sha256` manifest with an embedded signature (`signify -S -e` → `<archive>.sha256.sig`), and `restore.ksh` verifies both the signature and archive checksum in streaming constant memory via `signify -C` (while maintaining backward compatibility with legacy `.sig` files).

1. **Generate Signify Keypair:**
   ```bash
   doas mkdir -p /etc/signify
   # Interactive passphrase-protected key:
   doas signify -G -p /etc/signify/backup.pub -s /etc/signify/backup.sec -c "OpenBSD Backup Signing Key"
   # OR for unattended cron jobs (no passphrase prompt):
   doas signify -G -n -p /etc/signify/backup.pub -s /etc/signify/backup.sec -c "OpenBSD Backup Signing Key"
   doas chmod 600 /etc/signify/backup.sec
   ```
   > [!IMPORTANT]
   > Copy `/etc/signify/backup.pub` to a separate trusted machine (such as your Mac or offline USB) so you can independently verify archives before restoring.

2. **Automatic Key Detection:**
   - `backup.ksh` automatically detects `/etc/signify/backup.sec` if present and generates `<archive>.sha256.sig`.
   - `restore.ksh` automatically detects `/etc/signify/backup.pub` and validates signatures fail-closed during `--verify`, `--config-only`, and `--full` operations.

3. **Explicit Key Path:**
   ```bash
   # Create signed archive with custom key:
   doas backup.ksh -S /etc/signify/backup.sec

   # Verify signed archive with public key:
   restore.ksh --verify -S /etc/signify/backup.pub backup.tar.zst
   ```

4. **Lifecycle Integration:**
   - Signatures (`.sha256.sig`) are automatically transferred alongside archives during offsite SCP uploads (`-u / --upload`).
   - Old signature files (`.sha256.sig` and legacy `.sig`) are automatically pruned alongside archives by retention rules (`-k / --keep`).
   - Loop prevention rules strictly prevent signature files from being recursively ingested into future archives.

### Secrets Isolation (`--skip-secrets`)
When preparing archives for dotfile synchronization across multiple machines, distributing configs to public/team repositories, or uploading to untrusted storage, sensitive credentials must never be leaked.

The `--skip-secrets` flag (automatically enabled by default on the `config` profile) applies strict regular expression exclusions:
- **System Credential Databases & Shadow Mirrors:** Excludes `/etc/master.passwd`, `/etc/spwd.db`, `/etc/shadow`, `/etc/skey`, and all of `/var/backups` (OpenBSD's daily `/etc/security` copies of `master.passwd` and private keys). Retains world-readable `/etc/passwd` so UID/GID mappings remain intact.
- **SSH Host & User Private Keys:** Excludes `/etc/ssh/ssh_host_*_key` and user private keys (`~/.ssh/id_rsa`, `id_ed25519`, `id_ecdsa`, `id_dsa`, `id_ed25519_sk`, `id_ecdsa_sk`, `identity`, `*.pem`, `*.key`) while **preserving** public `.pub` keys (`id_*.pub`, `ssh_host_*_key.pub`) and `authorized_keys`.
- **Signing, TLS, ACME, VPN, Mail & Interface Credentials:** Excludes `/etc/signify/*.sec`, `/etc/age/*.key`, `/etc/ssl/private/*`, `/etc/acme/*`, `/etc/iked/private/*`, `/etc/isakmpd/private/*`, `/etc/wireguard/*.key`, `/etc/ipsec.secrets`, `/etc/hostname.*` (Wi-Fi `wpakey` / WireGuard `wgkey`), `/etc/mail/secrets`, and `/etc/mail/dkim/*`. Also redacts `wgkey`/`wpakey` in `_sysinfo/ifconfig.txt`.
- **User Credential Stores & Session State:** Excludes `~/.gnupg/private-keys-v1.d/*`, `~/.gnupg/secring.gpg`, `~/.password-store/*`, `~/.netrc`, `~/.git-credentials`, `~/.my.cnf`, `~/.pgpass`, `~/.aws/*`, `~/.kube/*`, `~/.docker/config.json`, shell histories (`~/.ksh_history`, `~/.bash_history`, `~/.zsh_history`), `~/.vim/undo/*`, `~/.viminfo`, `~/.Xauthority`, and `~/.sndio/cookie`.
- **Database Dumps:** Automatically suppresses MariaDB, PostgreSQL, and SQLite dumps when `--skip-secrets` is active.

### Ownership Model & Privilege Containment (`--chown`)
Because full system backups preserve root-owned credentials (`0600`), transferring archive ownership to a non-root user when running via `doas` or `sudo` would introduce privilege leakage on multi-user systems.

- **Strict Root Ownership by Default:** Archives capturing complete system states retain `root:wheel` (`0600`) ownership and `0700` working directories (enforced via `umask 077` across both `backup.ksh` and `restore.ksh`).
- **Automatic User Chown for Sanitized Archives:** When `--skip-secrets` is active (or when using `-p config`), the archive is verified free of sensitive system secrets. `backup.ksh` safely assigns ownership of the archive, checksum, and signature to the invoking non-root user (`$DOAS_USER` or `$SUDO_USER`).
- **Explicit Override (`--chown`):** If you explicitly want the archive assigned to your calling user despite containing system secrets, specify `--chown`.

### Live Restoration Guardrails & Safety Snapshots
Restoring configuration or system files onto a running production machine carries operational risk. `restore.ksh` includes safeguards against accidental overwrites:

1. **Pre-Restoration Integrity Verification:**
   Before extracting files in `--config-only` (`-C`) or `--full` (`-F`) modes, `restore.ksh` verifies the archive's SHA256 checksum and cryptographic signature (if present). If verification fails, extraction aborts immediately.

2. **Automated Safety Snapshot of `/etc`:**
   Whenever files are being restored directly to `/` (`--dest /`), `restore.ksh` creates an automatic timestamped safety snapshot:
   ```text
   /var/backups/etc.pre-restore.YYYYMMDD-HHMMSS.tar.gz
   ```
   If a misconfiguration occurs during restoration, you can immediately roll back `/etc` to its exact pre-restore state. Disable this snapshot with `--no-backup` if disk space is severely restricted.

3. **Interactive Overwrite Confirmation:**
   When running interactively in a terminal, `restore.ksh` prompts for confirmation before overwriting live configurations or system files:
   ```text
   WARNING: This operation will overwrite configuration files in '/'. Proceed? [y/N]:
   ```
   Pass `-f` / `--force` to bypass this prompt for unattended automation and recovery scripts.

4. **DUID-Safe `/etc/fstab` Protection & `pwd_mkdb` Rebuild:**
   When restoring directly to `/` (`--dest /`), `restore.ksh` automatically preserves your live `/etc/fstab` (so a fresh OpenBSD install on a new VPS, Raspberry Pi SD card, or replacement SSD never becomes unbootable due to mismatched disk DUIDs) and saves the archive's `fstab` to `/var/backups/fstab.from-backup` for reference. Pass `--overwrite-fstab` only if restoring onto the exact same disks. It also warns on OpenBSD release mismatches, rebuilds `/etc/pwd.db` & `/etc/spwd.db` via `pwd_mkdb -p /etc/master.passwd` after restoring `master.passwd`, and skips `/etc/passwd` when restoring `--skip-secrets` archives.

5. **Metadata Directory Isolation:**
   When running full extractions (`--full` or `--all`), `restore.ksh` isolates the embedded `_sysinfo/` (and legacy `openbsd_sysinfo.*`) directories using anchored OpenBSD `tar -s` rules (`^_sysinfo$`, `^_sysinfo/.*`) so metadata never pollutes `/` while user files containing `_sysinfo` in their name remain intact.

---

## Privilege & Permissions Matrix

To adhere to the principle of least privilege, `restore.ksh` allows read-only and inspection operations without root access, while system-altering operations strictly enforce `doas`/root requirements:

| Tool | Mode / Flag | Description | Requires Root (`doas`) |
| :--- | :--- | :--- | :---: |
| `backup.ksh` | *(all base operations)* | System configuration & hardware state capture | **Yes** *(reads `/etc/master.passwd`, raw disk devices)* |
| `backup.ksh` | `-e, --encrypt-key FILE` | Encrypt archive at rest with `age(1)` public key | **Yes** *(auto-detected from `/etc/age/backup.pub`)* |
| `backup.ksh` | `-S, --sign KEY_FILE` | Sign archive `.sha256` manifest with `signify(1)` | **Yes** *(reads private signing key)* |
| `backup.ksh` | `--skip-secrets` | Exclude credentials, hashes, private keys & DB dumps | **Yes** *(default on `config` profile)* |
| `backup.ksh` | `--chown` | Assign archive ownership to invoking user | **Yes** *(automatic with `--skip-secrets`, or explicit override)* |
| `restore.ksh` | `-i, --show-info` | Inspect archive manifest, packages, services, DUIDs | **No** |
| `restore.ksh` | `-c, --verify` | Verify SHA256 checksum, tar readability & signature | **No** |
| `restore.ksh` | `-S, --sig-key PUBKEY`| Validate OpenBSD `signify` digital signature | **No** *(with `-c` / `-i`)* |
| `restore.ksh` | `-K, --decrypt-key FILE` | Decrypt `.age` archives via `age(1)` identity file | *Inherits mode requirement* |
| `restore.ksh` | `-d, --diff` | Diff archive files against live system | **No** *(unless inspecting root-only files)* |
| `restore.ksh` | `-l, --list` | List or search contents within archive | **No** |
| `restore.ksh` | `-C, --config-only` | Restore `/etc`, `/root`, user scripts, and dotfiles | **Yes** |
| `restore.ksh` | `-F, --full` | Full extraction of archive to target filesystem | **Yes** |
| `restore.ksh` | `-p, --install-pkgs`| Reinstall recorded packages via `pkg_add -l` | **Yes** |
| `restore.ksh` | `-s, --enable-services` | Re-enable daemons via `rcctl` | **Yes** |
| `restore.ksh` | `-a, --all` | Complete turnkey bare-metal rebuild | **Yes** |
| `restore.ksh` | `--overwrite-fstab` | Allow overwriting live `/etc/fstab` on `/` | **Yes** *(live restore modes)* |
| `restore.ksh` | `-f, --force` | Bypass interactive confirmation and warnings | *Inherits mode requirement* |
| `restore.ksh` | `--no-backup` | Bypass pre-restore safety `/etc` snapshot | *Inherits mode requirement* |
| `quick-restore.sh` | *(embedded)* | Standalone rescue helper in `_sysinfo/` | **Yes** |

---

## Complete Command Reference

### `backup.ksh`

```
Usage: backup.ksh [OPTIONS]

Unified OpenBSD Backup Utility

Profiles:
  -p, --profile PROFILE     Select profile: server (or baremetal/rpi), desktop, laptop,
                            vps (or cloud), or config (default: auto-detected)
                            - server : Bare-metal server & RPi/ARM SBC (RAID/bioctl,
                                       sensors, CARP/trunk, daemon chroots, RPi boot
                                       config, optional /var/www and DB dumps).
                            - desktop: Desktop workstation (/etc, dotfiles, /home, fonts,
                                       display/sndioctl/wsconsctl, cache exclusions).
                            - laptop : Laptop/notebook (desktop features + battery safety
                                       check, touchpad, APM power, wireless configs).
                            - vps    : Cloud VPS & VMs (VirtIO storage/networking,
                                       cloud-init, serial console, RAM-aware compression).
                            - config : Fast backup of /etc, dotfiles, scripts, package lists.

Target & Destination:
  -d, --dest DIR            Destination directory for the archive (default: user home or /root)
  -o, --output FILE         Explicit output filepath for the archive
  -t, --temp-dir DIR        Temporary scratch directory (default: $TMPDIR, /var/tmp, or /tmp)
  -u, --upload DEST         Upload archive, checksum, and signature via scp (user@host:/path)
      --ssh-key FILE        Explicit SSH private key for remote scp upload
  -k, --keep COUNT          Retain only COUNT most recent backups in dest dir, pruning older ones

Compression & Options:
  -f, --force               Bypass safety checks (battery warnings, scratch space alerts)
  -J, --xz                  Use XZ compression (.tar.xz) via xz(1) pipe (RAM-bounded)
  -Z, --zstd                Use Zstandard compression (.tar.zst) via zstd(1) pipe
  -w, --web                 Include /var/www (useful for server/vps web servers)
  -m, --mariadb             Include MariaDB/MySQL database dump
      --postgres            Include PostgreSQL database dump (via pg_dumpall)
      --sqlite FILE         Safely snapshot a live SQLite database into _sysinfo/sqlite/ (repeatable)
  -a, --all                 Include /var/www plus installed MariaDB/PostgreSQL dumps
  -D, --include-downloads   Include ~/Downloads directory (excluded by default on desktop/laptop)
  -C, --include-caches      Include browser and build caches (excluded by default)
  -N, --no-excludes         Disable built-in cache/download exclusions (loop protection stays active)
  -x, --exclude PATTERN     Add custom tar exclusion pattern (repeatable)
      --exclude-file FILE   Read newline-delimited exclusion patterns from FILE
  -n, --notify              Send desktop notification on completion (desktop/laptop profile)
  -q, --quiet               Suppress informational output (emit warnings/errors only; ideal for cron)
  -v, --verbose             Enable verbose output during tar archiving
  -h, --help                Display this help message and exit

Security, Encryption, Signing & Ownership:
  -e, --encrypt-key FILE    Encrypt archive at rest with age(1) public key/recipients file (.age)
                            (auto-detected from /etc/age/backup.pub if present)
      --no-encrypt          Disable automatic encryption even if /etc/age/backup.pub exists
  -S, --sign KEY_FILE       Sign archive SHA256 manifest using OpenBSD signify(1) secret key
                            (auto-detected from /etc/signify/backup.sec if present)
      --skip-secrets        Exclude credentials, hashes, private keys, and DB dumps
                            (enabled by default on 'config' profile)
      --chown               Allow assigning archive ownership to calling user
                            (automatic when --skip-secrets is active)
```

### `restore.ksh`

```
Usage: restore.ksh <MODE> [OPTIONS] <ARCHIVE> [PATH]

OpenBSD Disaster Recovery & Rapid Restoration Utility

Modes (select one):
  -i, --show-info ARCHIVE      Inspect and display backup metadata (manifest, DUIDs,
                               package counts, enabled services, hardware state)
  -c, --verify ARCHIVE         Verify archive SHA256 checksum, signify signature, and readability
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
  -K, --decrypt-key FILE       age(1) identity (private key) file for .age encrypted archives
                               (also respects AGE_KEY_FILE environment variable)
  -S, --sig-key PUBKEY         Verify archive signature using OpenBSD signify(1) public key
      --overwrite-fstab        Allow overwriting live /etc/fstab during restore to /
                               (by default, /etc/fstab is protected to preserve disk DUIDs)
  -f, --force                  Bypass interactive confirmation and verification warnings
      --no-backup              Do not create safety backup of /etc before restoring
  -n, --dry-run                Simulate restoration actions without modifying system
  -v, --verbose                Enable verbose extraction output
  -h, --help                   Display this help message and exit
```

---

## Exclusion Rules & Custom Filtering

### Built-in Loop, Socket & Recursion Protection (Always Active)
OpenBSD's native `tar(1)` (based on `pax(1)`) does not support GNU `--exclude` options. `backup.ksh` natively implements exclusions using OpenBSD `tar -s replstr` pattern substitution rules (`-s ',pattern,,'`), where paths that substitute to the empty string are not archived.

To prevent accidental recursion, exponential archive expansion, socket errors, and corrupted backup data, `backup.ksh` strictly enforces these exclusions on every run across all profiles (while **preserving** personal `.tar.gz`/`.tar.xz`/`.tgz` files in `/home` or `/var/www`):
- **Prior Backup Archives, Checksums & Signatures:** `.*_backup_.*\.tar\..*`, `.*_backup_.*\.tgz.*`, `.*_backup_.*\.sha256.*`, `.*_backup_.*\.sig$`
- **Temporary Staging & Pre-Restore Files:** `.*/\..*_backup_.*\.tmp\..*`, `^var/backups/etc\.pre-restore\..*\.tar\.gz$`
- **UNIX Domain Sockets:** `.*\.gnupg/S\..*`, `.*\.sock$`, `.*\.socket$` (OpenBSD `ustar` format cannot archive dynamic IPC sockets)
- **Active Target Output Files:** Automatically excludes the current archive, staging temp file, checksum, and signature using regex-escaped basenames
- **Anchored Foreign & Network Mounts:** Parses active mount points to exclude `nfs`, `fuse`, `fusefs`/sshfs, `mfs`, `tmpfs`, and `smbfs` anchored strictly at `^<mountpoint>` (so an `mfs` mount on `/tmp` never excludes unrelated `*/tmp/*` user directories)

> [!TIP]
> **Delimiter Collision Safety:** When custom or built-in exclusion patterns contain commas (e.g. `pattern,with,commas`), `backup.ksh` dynamically switches the substitution delimiter from `,` to `@`, `:`, or `|` (e.g., `-s '@pattern@@'`), preventing pattern corruption or tar syntax errors.

### Secrets Isolation Exclusions (`--skip-secrets`)
When `--skip-secrets` is enabled (or on the `config` profile), the following targets are automatically excluded:
- **System hashes & shadow mirrors:** `/etc/master.passwd`, `/etc/spwd.db`, `/etc/shadow`, `/etc/skey`, and `/var/backups` (OpenBSD's daily `/etc/security` copies) — while preserving `/etc/passwd`
- **Host private keys:** `/etc/ssh/ssh_host_*_key` (public `.pub` keys and `authorized_keys` are preserved)
- **Signing, TLS, ACME, VPN, mail & interface secrets:** `/etc/signify/*.sec`, `/etc/age/*.key`, `/etc/age/backup.sec`, `/etc/ssl/private/*`, `/etc/acme/*`, `/etc/iked/private/*`, `/etc/isakmpd/private/*`, `/etc/wireguard/*.key`, `/etc/ipsec.secrets`, `/etc/hostname.*`, `/etc/mail/secrets`, and `/etc/mail/dkim/*` (plus `wgkey`/`wpakey`/`nwkey`/`wgpka` redaction in `_sysinfo/ifconfig.txt` and `wireless_interfaces.txt`)
- **User private keys, credentials & session state:** `~/.ssh/id_rsa`, `id_dsa`, `id_ecdsa`, `id_ecdsa_sk`, `id_ed25519`, `id_ed25519_sk`, `identity`, `~/.ssh/*.pem`, `~/.ssh/*.key` (preserving `id_*.pub` and `authorized_keys`), `~/.gnupg/private-keys-v1.d/*`, `~/.gnupg/secring.gpg`, `~/.password-store/*`, `~/.netrc`, `~/.git-credentials`, `~/.my.cnf`, `~/.pgpass`, `~/.aws/*`, `~/.kube/*`, `~/.docker/config.json`, shell histories (`~/.ksh_history`, `~/.bash_history`, `~/.zsh_history`, `~/.history`), `~/.vim/undo/*`, `~/.viminfo`, `~/.Xauthority`, and `~/.sndio/cookie`
- **Automated database dumps:** MariaDB, PostgreSQL, and SQLite snapshots are suppressed

### Default Cache & Ephemeral Exclusions
In addition to loop safeguards, the `desktop` and `laptop` profiles skip ephemeral caches, build artifacts, and downloads (disable with `-N / --no-excludes` or include caches with `-C / --include-caches`):
- **User Caches:** `~/.cache`, `~/.thumbnails`, `~/.local/share/Trash`
- **Browser Profiles & Electron:** Firefox caches (`cache2`, `startupCache`, `shader-cache`, `storage/temporary` — preserving `storage/default` so browser extension settings survive restore), Chromium / Chrome / Electron caches (`Code Cache`, `GPUCache`)
- **Development & Build Caches:**
  - Cargo / Rust: `~/.cargo/registry`, `~/.cargo/git`, `target/debug`, `target/release`
  - Go: `~/go/pkg/mod/cache`
  - Java: `~/.gradle/caches`, `~/.m2/repository`
  - Node: `node_modules`
  - Python: `__pycache__`, `.pytest_cache`, `.venv`, `venv`
- **Transient Files:** `*.core`, `*.swp`, `recently-used.xbel`
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
5. **Turnkey Restore:** Run `doas restore.ksh --all -S /etc/signify/backup.pub backup.tar.gz` to reinstall all packages, re-enable services, and restore configuration files. `restore.ksh` verifies checksum & signify signatures, automatically captures an `/etc` safety snapshot, and prompts before overwriting live configurations.
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
2. **Turnkey Restore:** Transfer the archive and run `doas restore.ksh --all -f backup.tar.gz` (using `-f` to bypass interactive prompts in serial console or cloud-init automation).
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

#### SQLite
```bash
# Snapshots captured via --sqlite are stored under _sysinfo/sqlite/ with '/' replaced by '_':
# 1. Stop the service using the database, then copy the snapshot back into place:
doas cp _sysinfo/sqlite/var_www_app.db /var/www/app.db

# 2. Restore appropriate ownership and permissions, then restart the service:
doas chown www:www /var/www/app.db
```

---

## Autonomous Emergency Recovery (`quick-restore.sh`)

If you find yourself on a recovery console or live environment without `restore.ksh`, you can leverage the autonomous rescue helper embedded inside every archive:

```bash
# 1. Extract only the embedded _sysinfo metadata folder:
#    gzip:
gzip -dc backup.tar.gz | tar -xpf - _sysinfo
#    zstd:
zstd -dc backup.tar.zst | tar -xpf - _sysinfo
#    age-encrypted zstd:
age -d -i backup.age.key backup.tar.zst.age | zstd -dc | tar -xpf - _sysinfo

# 2. Run the embedded rescue helper:
sh _sysinfo/quick-restore.sh
```

This helper will print the backup manifest, hardware classification, display exact commands to restore packages, re-enable services, run `fw_update`, and provide profile-tailored post-restoration guidance.

---

## Automated Scheduling with `cron`

Configure automated recurring backups by editing root's crontab (`doas crontab -e`).

> [!TIP]
> Use `-q` (`--quiet`) instead of `>/dev/null 2>&1`! OpenBSD's `cron(8)` automatically emails `root` whenever a job writes output, so `-q` stays completely silent on success while immediately alerting you if `tar`, database dumps, signing, encryption, or `scp` uploads fail. Also store backups in a dedicated directory (e.g., `/var/db/openbsd-backups` or an external mount) and generate your unattended signing key with `signify -G -n`.

```crontab
# Cloud VPS: daily encrypted zstd backup at 02:30 AM with 7-day local retention and offsite SCP upload:
30 2 * * * /usr/local/sbin/backup.ksh -q -p vps -Z -e /etc/age/backup.pub -S /etc/signify/backup.sec -w -k 7 -d /var/db/openbsd-backups --ssh-key /root/.ssh/id_backup -u backupuser@nas.lan:/storage/vps-backups/

# Raspberry Pi (OpenBSD arm64): daily encrypted zstd backup at 03:00 AM (captures MSDOS boot config.txt):
0 3 * * * /usr/local/sbin/backup.ksh -q -p server -Z -e /etc/age/backup.pub -S /etc/signify/backup.sec -k 5 -d /mnt/usb-backups --ssh-key /root/.ssh/id_backup -u backupuser@nas.lan:/storage/rpi-backups/

# OpenBSD Desktop Workstation: daily zstd backup at 02:00 AM:
0 2 * * * /usr/local/sbin/backup.ksh -q -p desktop -Z -e /etc/age/backup.pub -k 14 -d /mnt/backups

# Hourly lightweight configuration & dotfiles backup (secrets excluded, chowned to user for sync):
0 * * * * /usr/local/sbin/backup.ksh -q -p config --skip-secrets --chown -k 24 -d /var/db/openbsd-backups/config
```

> [!NOTE]
> `--keep` prunes old archives on the local host only. Configure separate retention pruning (or ZFS/HAMMER/filesystem snapshots with append-only permissions) on your remote backup server so remote storage does not grow unbounded and a compromised VPS cannot delete historical backups.

---

## Testing & Verification

An automated verification test suite containing 92–99 comprehensive assertions (depending on installed optional tools `xz`, `zstd`, and `age`) is provided in [`tests/test_runner.sh`](tests/test_runner.sh) and runs natively on both **OpenBSD** and **macOS**. It validates shell syntax across `backup.ksh`, `restore.ksh`, and the embedded `quick-restore.sh`; OpenBSD base `tar(1)` / `rcctl(8)` / `bioctl(8)` / `pfctl(8)` compatibility invariants; profile normalization and auto-detection (including Raspberry Pi / ARM SBC, VPS, laptop, desktop, and bare-metal servers); 3-tier XZ memory bounding; real `backup.ksh` exclusion and `--skip-secrets` rules (preserving user `.tar.gz`/`.tar.xz`/`.tgz` archives, Firefox `storage/default`, and SSH `.pub` keys while stripping `/var/backups`, `/etc/signify/*.sec`, `/etc/hostname.*`, `/etc/acme/*`, `/etc/iked/private/*`, and user secrets); multi-format retention pruning; and end-to-end `restore.ksh` workflows across `gzip`, `xz`, `zstd`, and `age`-encrypted archives (including `/etc/fstab` DUID protection and non-root `--diff`).

To run the test suite:

```bash
sh tests/test_runner.sh
```

---

## License

ISC License. Copyright (c) 2026 Marcus Swenson <src@marcusswenson.com>.

See [LICENSE](LICENSE) for the complete license text.
