#!/bin/ksh
# ==============================================================================
# backup.ksh
#
# Unified, robust, and profile-driven backup utility for OpenBSD.
# Protects system configurations, user customizations/dotfiles, service states,
# and bare-metal hardware metadata for fast and reliable disaster recovery.
#
# Profiles:
#   server  : Physical baremetal servers & ARM SBCs / Raspberry Pi (hardware
#             RAID/bioctl, sensors, bonded NICs, PF rules, daemon chroots,
#             RPi MSDOS boot config, web directories, databases).
#             Alias: baremetal, bare-metal, rpi.
#   desktop : Workstations (smart cache exclusions, multi-monitor xrandr,
#             wsconsctl, sndioctl/audio levels, desktop alerts).
#             Alias: workstation.
#   laptop  : Laptops/notebooks (desktop features + battery safety checks,
#             apm/apmd state, touchpad wsconsctl, wireless configs, brightness).
#             Alias: notebook.
#   vps     : Cloud VPS & virtual machines (VirtIO devices, cloud-init, serial
#             console, memory-bounded compression, low-scratch awareness).
#             Alias: cloud, vm.
#   config  : Ultra-fast dotfiles + /etc sync without heavy media or documents.
#             Alias: dotfiles.
#
# Copyright (c) 2026 Marcus Swenson <src@marcusswenson.com>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
# ==============================================================================

set -e
set -o pipefail 2>/dev/null || true

# Enforce strict permissions from the very beginning (0600 files, 0700 dirs)
# Prevents sensitive private keys, shadow passwords, and DB dumps from exposure.
umask 077

PROGNAME="${0##*/}"
LOCK_DIR="/var/run/openbsd-backup.lock"
HOSTNAME=$(hostname)
TIMESTAMP=$(date '+%Y.%m.%d-%H.%M.%S')
SYSINFO_STAGE_DIR=""
SYSINFO_DIR=""
RPI_BOOT_MNT=""
RPI_BOOT_MOUNTED=0
TAR_ERR_FILE=""
TAR_STATUS_FILE=""
COMP_STATUS_FILE=""
TMP_BACKUP_FILE=""
BACKUP_HAD_ERROR=0
QUIET=0

usage() {
    cat <<EOF
Usage: ${PROGNAME} [OPTIONS]

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
  -t, --temp-dir DIR        Temporary scratch directory (default: \$TMPDIR, /var/tmp, or /tmp)
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
EOF
}

log_info() {
    [ "$QUIET" -eq 0 ] && echo "$@" || true
}

log_warn() {
    echo "$@" >&2
}

syslog_msg() {
    typeset prio="$1"
    shift
    if command -v logger >/dev/null 2>&1; then
        logger -p "daemon.${prio}" -t openbsd-backup -- "$*" 2>/dev/null || true
    fi
}

# Allow --help / -h before checking root permissions
for arg in "$@"; do
    if [ "$arg" = "-h" ] || [ "$arg" = "--help" ]; then
        usage
        exit 0
    fi
done

# Ensure script is executed as root for access to /etc, master.passwd, and disklabels
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: ${PROGNAME} must be run as root (e.g., via doas)." >&2
    exit 1
fi

# Acquire process lock to prevent concurrent overlapping executions
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    if [ -f "${LOCK_DIR}/pid" ]; then
        EXISTING_PID=$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)
        if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
            echo "Error: Another backup process is currently running (PID ${EXISTING_PID})." >&2
            exit 1
        else
            log_warn "Removing stale lock from PID ${EXISTING_PID:-unknown}..."
            rm -rf "${LOCK_DIR}"
            if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
                echo "Error: Could not acquire lock ${LOCK_DIR} (concurrent start)." >&2
                exit 1
            fi
        fi
    else
        # Recover if a previous process crashed between mkdir and writing pid
        sleep 1
        if [ -f "${LOCK_DIR}/pid" ]; then
            EXISTING_PID=$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)
            echo "Error: Another backup process is starting/running (PID ${EXISTING_PID:-unknown})." >&2
            exit 1
        fi
        log_warn "Removing orphaned lock directory ${LOCK_DIR} (no PID file)..."
        rm -rf "${LOCK_DIR}"
        if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
            echo "Error: Could not acquire lock ${LOCK_DIR}." >&2
            exit 1
        fi
    fi
fi
echo "$$" > "${LOCK_DIR}/pid"

# Cleanup trap for lock directory, mounts, and temporary files
cleanup() {
    EXIT_CODE=$?
    if [ "$RPI_BOOT_MOUNTED" -eq 1 ] && [ -n "${RPI_BOOT_MNT}" ]; then
        umount "${RPI_BOOT_MNT}" 2>/dev/null || true
    fi
    [ -n "${RPI_BOOT_MNT}" ] && rmdir "${RPI_BOOT_MNT}" 2>/dev/null || true
    [ -n "${LOCK_DIR}" ] && rm -rf "${LOCK_DIR}" 2>/dev/null || true
    [ -n "${SYSINFO_STAGE_DIR}" ] && rm -rf "${SYSINFO_STAGE_DIR}" 2>/dev/null || true
    [ -n "${SYSINFO_DIR}" ] && rm -rf "${SYSINFO_DIR}" 2>/dev/null || true
    [ -n "${TAR_ERR_FILE}" ] && rm -f "${TAR_ERR_FILE}" 2>/dev/null || true
    [ -n "${TAR_STATUS_FILE}" ] && rm -f "${TAR_STATUS_FILE}" 2>/dev/null || true
    [ -n "${COMP_STATUS_FILE}" ] && rm -f "${COMP_STATUS_FILE}" 2>/dev/null || true
    [ -n "${TMP_BACKUP_FILE}" ] && rm -f "${TMP_BACKUP_FILE}" 2>/dev/null || true
    exit $EXIT_CODE
}
trap cleanup EXIT INT TERM QUIT

# Safe shell-escaping helper to prevent command injection in subshells
shell_escape() {
    typeset s="$1"
    printf "%s" "$s" | sed "s/'/'\\\\''/g"
}

# Escape BRE regex metacharacters for OpenBSD tar(1) -s replstr
regex_escape() {
    typeset s="$1"
    printf "%s" "$s" | sed 's/[\\.\[^$*]/\\&/g'
}

# Escape BRE regex metacharacters except '*', converting '*' to '.*'
glob_to_bre() {
    typeset s="$1"
    printf "%s" "$s" | sed 's/[\\.\[^$]/\\&/g; s/\*/.*/g'
}

# Detect invoking non-root user when run via doas/sudo
if [ -n "$DOAS_USER" ]; then
    FINAL_USER="$DOAS_USER"
    USER_HOME=$(awk -F: -v user="$DOAS_USER" '$1 == user {print $6}' /etc/passwd)
elif [ -n "$SUDO_USER" ]; then
    FINAL_USER="$SUDO_USER"
    USER_HOME=$(awk -F: -v user="$SUDO_USER" '$1 == user {print $6}' /etc/passwd)
else
    FINAL_USER="root"
    USER_HOME="/root"
fi

# Default settings
PROFILE=""
DEST_DIR=""
CUSTOM_OUTPUT=""
SCRATCH_DIR="${TMPDIR:-/tmp}"
CUSTOM_SCRATCH=0
UPLOAD_DEST=""
SSH_KEY=""
KEEP_COUNT=0
COMPRESSOR="gzip"
BACKUP_WEB=0
BACKUP_MARIADB=0
BACKUP_POSTGRES=0
BACKUP_ALL_MODE=0
INCLUDE_DOWNLOADS=0
INCLUDE_CACHES=0
NO_EXCLUDES=0
SEND_NOTIFY=0
VERBOSE=0
FORCE=0
SIGN_KEY=""
ENCRYPT_KEY=""
NO_ENCRYPT=0
SKIP_SECRETS=0
FORCE_CHOWN=0
set -A USER_EXCLUDES
set -A SQLITE_DBS
EXCLUDE_FILE=""

# Argument parsing
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--profile)
            if [[ -n "$2" && "$2" != -* ]]; then
                PROFILE="$2"
                shift 2
            else
                echo "Error: --profile requires an argument (server, desktop, laptop, vps, or config)." >&2
                exit 1
            fi
            ;;
        -d|--dest)
            if [[ -n "$2" && "$2" != -* ]]; then
                DEST_DIR="$2"
                shift 2
            else
                echo "Error: --dest requires a directory path." >&2
                exit 1
            fi
            ;;
        -o|--output)
            if [[ -n "$2" && "$2" != -* ]]; then
                CUSTOM_OUTPUT="$2"
                shift 2
            else
                echo "Error: --output requires a file path." >&2
                exit 1
            fi
            ;;
        -t|--temp-dir)
            if [[ -n "$2" && "$2" != -* ]] && [ -d "$2" ]; then
                SCRATCH_DIR="$2"
                CUSTOM_SCRATCH=1
                shift 2
            else
                echo "Error: --temp-dir requires an existing directory." >&2
                exit 1
            fi
            ;;
        -u|--upload)
            if [[ -n "$2" && "$2" != -* ]]; then
                UPLOAD_DEST="$2"
                shift 2
            else
                echo "Error: --upload requires a destination argument (user@host:/path)." >&2
                exit 1
            fi
            ;;
        --ssh-key)
            if [[ -n "$2" && "$2" != -* ]] && [ -f "$2" ]; then
                SSH_KEY="$2"
                shift 2
            else
                echo "Error: --ssh-key requires a valid SSH key file path." >&2
                exit 1
            fi
            ;;
        -k|--keep)
            if [ -n "$2" ] && [ "$2" -ge 1 ] 2>/dev/null; then
                KEEP_COUNT="$2"
                shift 2
            else
                echo "Error: --keep requires a positive integer argument." >&2
                exit 1
            fi
            ;;
        -f|--force)
            FORCE=1
            shift
            ;;
        -J|--xz)
            COMPRESSOR="xz"
            shift
            ;;
        -Z|--zstd)
            COMPRESSOR="zstd"
            shift
            ;;
        -w|--web)
            BACKUP_WEB=1
            shift
            ;;
        -m|--mariadb)
            BACKUP_MARIADB=1
            shift
            ;;
        --postgres)
            BACKUP_POSTGRES=1
            shift
            ;;
        --sqlite)
            if [[ -n "$2" && "$2" != -* ]] && [ -f "$2" ]; then
                set -A SQLITE_DBS -- "${SQLITE_DBS[@]}" "$2"
                shift 2
            else
                echo "Error: --sqlite requires an existing database file path." >&2
                exit 1
            fi
            ;;
        -a|--all)
            BACKUP_WEB=1
            BACKUP_ALL_MODE=1
            shift
            ;;
        -D|--include-downloads)
            INCLUDE_DOWNLOADS=1
            shift
            ;;
        -C|--include-caches)
            INCLUDE_CACHES=1
            shift
            ;;
        -N|--no-excludes)
            NO_EXCLUDES=1
            shift
            ;;
        -x|--exclude)
            if [ -n "$2" ]; then
                set -A USER_EXCLUDES -- "${USER_EXCLUDES[@]}" "$2"
                shift 2
            else
                echo "Error: --exclude requires a pattern argument." >&2
                exit 1
            fi
            ;;
        --exclude-file)
            if [ -n "$2" ] && [ -f "$2" ]; then
                EXCLUDE_FILE="$2"
                shift 2
            else
                echo "Error: --exclude-file requires a valid file path." >&2
                exit 1
            fi
            ;;
        -n|--notify)
            SEND_NOTIFY=1
            shift
            ;;
        -q|--quiet)
            QUIET=1
            shift
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -e|--encrypt-key)
            if [[ -n "$2" && "$2" != -* ]] && [ -f "$2" ]; then
                ENCRYPT_KEY="$2"
                shift 2
            else
                echo "Error: --encrypt-key requires a valid age public key/recipients file." >&2
                exit 1
            fi
            ;;
        --no-encrypt)
            NO_ENCRYPT=1
            shift
            ;;
        -S|--sign)
            if [[ -n "$2" && "$2" != -* ]] && [ -f "$2" ]; then
                SIGN_KEY="$2"
                shift 2
            else
                echo "Error: --sign requires a valid secret key file path." >&2
                exit 1
            fi
            ;;
        --skip-secrets|--no-secrets)
            SKIP_SECRETS=1
            shift
            ;;
        --chown)
            FORCE_CHOWN=1
            shift
            ;;
        *)
            echo "Error: Unknown option '$1'" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Resolve -a / --all: enable installed database engines automatically
if [ "$BACKUP_ALL_MODE" -eq 1 ]; then
    command -v mysqldump >/dev/null 2>&1 && BACKUP_MARIADB=1
    if command -v pg_dumpall >/dev/null 2>&1 || [ -x "/usr/local/bin/pg_dumpall" ]; then
        BACKUP_POSTGRES=1
    fi
fi

# Hardware & Environment Auto-Detection
detect_environment() {
    HW_VENDOR=$(sysctl -n hw.vendor 2>/dev/null || true)
    HW_PRODUCT=$(sysctl -n hw.product 2>/dev/null || true)
    HW_VERSION=$(sysctl -n hw.version 2>/dev/null || true)
    HW_DISKNAMES=$(sysctl -n hw.disknames 2>/dev/null || true)
    HW_MACHINE=$(sysctl -n hw.machine 2>/dev/null || uname -m)
    DMESG_BOOT=$(dmesg 2>/dev/null | head -n 100 || true)

    DETECTED_ENV="server"
    DETECTED_DETAIL="Bare-metal Physical Server"

    # 1. Virtual Machine / Cloud VPS Detection
    IS_VM=0
    VM_TYPE=""
    case "${HW_VENDOR} ${HW_PRODUCT} ${HW_VERSION}" in
        *[Qq][Ee][Mm][Uu]*|*[Kk][Vv][Mm]*|*[Bb][Oo][Cc][Hh][Ss]*)
            IS_VM=1; VM_TYPE="QEMU / KVM Virtual Machine" ;;
        *[Vv][Ii][Rr][Tt][Uu][Aa][Ll][Bb][Oo][Xx]*)
            IS_VM=1; VM_TYPE="Oracle VirtualBox" ;;
        *[Vv][Mm][Ww][Aa][Rr][Ee]*)
            IS_VM=1; VM_TYPE="VMware Virtual Platform" ;;
        *[Xx][Ee][Nn]*|*[Aa][Mm][Aa][Zz][Oo][Nn]*)
            IS_VM=1; VM_TYPE="Xen / Amazon EC2 Instance" ;;
        *[Dd][Ii][Gg][Ii][Tt][Aa][Ll][Oo][Cc][Ee][Aa][Nn]*)
            IS_VM=1; VM_TYPE="DigitalOcean Droplet" ;;
        *[Vv][Uu][Ll][Tt][Rr]*)
            IS_VM=1; VM_TYPE="Vultr Cloud Compute" ;;
        *[Hh][Ee][Tt][Zz][Nn][Ee][Rr]*)
            IS_VM=1; VM_TYPE="Hetzner Cloud" ;;
        *[Gg][Oo][Oo][Gg][Ll][Ee]*)
            IS_VM=1; VM_TYPE="Google Compute Engine" ;;
        *[Mm][Ii][Cc][Rr][Oo][Ss][Oo][Ff][Tt]*)
            IS_VM=1; VM_TYPE="Microsoft Azure / Hyper-V" ;;
        *OpenBSD\ VMM*|*vmm*)
            IS_VM=1; VM_TYPE="OpenBSD VMM (vmd)" ;;
    esac

    if [ "$IS_VM" -eq 0 ]; then
        if echo "${HW_DISKNAMES}" | grep -qE 'vioblk|xbd'; then
            IS_VM=1
            VM_TYPE="VirtIO / Cloud Virtual Storage"
        elif echo "${DMESG_BOOT}" | grep -qE 'hypervisor:|virtio[0-9]|OpenBSD VMM'; then
            IS_VM=1
            VM_TYPE="Virtual Machine / Cloud Hypervisor"
        fi
    fi

    # 2. Raspberry Pi / ARM SBC Detection
    IS_RPI=0
    RPI_DETAIL=""
    case "${HW_VENDOR} ${HW_PRODUCT} ${HW_VERSION}" in
        *[Rr]aspberry*[Pp]i*)
            IS_RPI=1
            RPI_DETAIL="${HW_PRODUCT}"
            ;;
    esac
    if [ "$IS_RPI" -eq 0 ]; then
        if echo "${DMESG_BOOT}" | grep -qiE 'raspberry pi|bcm2711|bcm2837|bcm2712'; then
            IS_RPI=1
            RPI_DETAIL="Raspberry Pi (${HW_MACHINE})"
        fi
    fi

    # 3. Laptop / Mobile Notebook Detection
    IS_LAPTOP=0
    LAPTOP_DETAIL=""
    if command -v apm >/dev/null 2>&1; then
        APM_RAW=$(apm 2>/dev/null || true)
        if echo "$APM_RAW" | grep -qE 'Battery status: (high|low|critical|charging)|Remaining battery life:'; then
            IS_LAPTOP=1
            LAPTOP_DETAIL="APM Battery Subsystem Active"
        fi
    fi

    if [ "$IS_LAPTOP" -eq 0 ]; then
        if sysctl hw.sensors 2>/dev/null | grep -qE 'acpibat|battery'; then
            IS_LAPTOP=1
            LAPTOP_DETAIL="ACPI Battery Sensors Detected"
        fi
    fi

    if [ "$IS_LAPTOP" -eq 0 ]; then
        case "${HW_PRODUCT} ${HW_VERSION}" in
            *[Tt][Hh][Ii][Nn][Kk][Pp][Aa][Dd]*|*[Ll][Aa][Tt][Ii][Tt][Uu][Dd][Ee]*|*[Xx][Pp][Ss]*|\
            *[Mm][Aa][Cc][Bb][Oo][Oo][Kk]*|*[Ee][Ll][Ii][Tt][Ee][Bb][Oo][Oo][Kk]*|*[Nn][Oo][Tt][Ee][Bb][Oo][Oo][Kk]*|\
            *[Ll][Aa][Pp][Tt][Oo][Pp]*|*[Yy][Oo][Gg][Aa]*|*[Zz][Ee][Nn][Bb][Oo][Oo][Kk]*)
                IS_LAPTOP=1
                LAPTOP_DETAIL="${HW_PRODUCT}"
                ;;
        esac
    fi

    # 4. Desktop Workstation Detection (X11 / GUI environment active)
    IS_DESKTOP=0
    if [ -n "$DISPLAY" ] || pgrep -x xenodm >/dev/null 2>&1 || pgrep -x Xorg >/dev/null 2>&1 || pgrep -x wayland >/dev/null 2>&1; then
        IS_DESKTOP=1
    fi

    # Auto-detection hierarchy:
    # 1. Laptop (battery present takes precedence)
    # 2. Desktop (GUI active, non-laptop)
    # 3. Cloud VPS (hypervisor active, headless)
    # 4. Raspberry Pi / ARM SBC (mapped to server profile with RPi boot capture)
    # 5. Bare-metal Server (physical, headless)
    if [ "$IS_LAPTOP" -eq 1 ]; then
        DETECTED_ENV="laptop"
        DETECTED_DETAIL="Laptop / Mobile Notebook (${LAPTOP_DETAIL})"
    elif [ "$IS_DESKTOP" -eq 1 ]; then
        DETECTED_ENV="desktop"
        if [ "$IS_RPI" -eq 1 ]; then
            DETECTED_DETAIL="Desktop Workstation on ${RPI_DETAIL}"
        else
            DETECTED_DETAIL="Desktop Workstation (Active Display)"
        fi
    elif [ "$IS_VM" -eq 1 ]; then
        DETECTED_ENV="vps"
        DETECTED_DETAIL="Cloud VPS / Virtual Machine (${VM_TYPE})"
    elif [ "$IS_RPI" -eq 1 ]; then
        DETECTED_ENV="server"
        DETECTED_DETAIL="Raspberry Pi / ARM SBC (${RPI_DETAIL})"
    else
        DETECTED_ENV="server"
        SERVER_DESC="${HW_VENDOR} ${HW_PRODUCT}"
        [ -z "$(echo "$SERVER_DESC" | tr -d ' ')" ] && SERVER_DESC="Generic Physical Hardware"
        DETECTED_DETAIL="Bare-metal Physical Server (${SERVER_DESC})"
    fi
}

# Normalize profile alias
case "$PROFILE" in
    baremetal|bare-metal|rpi|raspberrypi|raspberry-pi)
        PROFILE="server"
        ;;
    workstation)
        PROFILE="desktop"
        ;;
    notebook)
        PROFILE="laptop"
        ;;
    cloud|vm)
        PROFILE="vps"
        ;;
    dotfiles)
        PROFILE="config"
        ;;
esac

# Auto-detect profile if none specified
if [ -z "$PROFILE" ]; then
    detect_environment
    PROFILE="$DETECTED_ENV"
    log_info "Notice: Auto-detected environment: ${DETECTED_DETAIL} -> Profile: ${PROFILE}"
else
    detect_environment
fi

case "$PROFILE" in
    desktop|laptop|server|vps|config) ;;
    *)
        echo "Error: Invalid profile '${PROFILE}'. Choose from: server (or baremetal/rpi), desktop, laptop, vps, config." >&2
        exit 1
        ;;
esac

# Auto-skip secrets on 'config' profile unless explicitly disabled
if [ "$PROFILE" = "config" ] && [ "$SKIP_SECRETS" -eq 0 ]; then
    SKIP_SECRETS=1
    log_info "Notice: Config profile active: System secrets and password hashes excluded by default."
fi

# Auto-detect age encryption key if not explicitly disabled
if [ "$NO_ENCRYPT" -eq 0 ] && [ -z "$ENCRYPT_KEY" ] && [ -f "/etc/age/backup.pub" ]; then
    ENCRYPT_KEY="/etc/age/backup.pub"
fi

if [ -n "$ENCRYPT_KEY" ]; then
    if ! command -v age >/dev/null 2>&1; then
        echo "Error: Encryption requested (${ENCRYPT_KEY}) but 'age' is not installed (pkg_add age)." >&2
        exit 1
    fi
fi

# Pre-flight check: Laptop battery level and AC status
if [ "$PROFILE" = "laptop" ] && command -v apm >/dev/null 2>&1; then
    AC_STATUS=$(apm -a 2>/dev/null || echo 255)
    BAT_PCT=$(apm -l 2>/dev/null || echo 255)
    # apm -a: 0 = disconnected (on battery), 1 = connected (on AC power)
    if [ "$AC_STATUS" = "0" ] && [ "$BAT_PCT" -ne 255 ] && [ "$BAT_PCT" -le 20 ]; then
        echo "" >&2
        echo "============================================================" >&2
        echo " WARNING: Running on battery power with only ${BAT_PCT}% charge remaining!" >&2
        echo " Heavy compression operations may rapidly drain the battery." >&2
        echo " Please connect AC power to prevent unexpected shutdown." >&2
        echo "============================================================" >&2
        if [ "$FORCE" -eq 0 ]; then
            if [ -t 0 ]; then
                echo -n "Do you wish to proceed anyway? [y/N]: " >&2
                read CONFIRM
                case "$CONFIRM" in
                    [yY]|[yY][eE][sS]) ;;
                    *)
                        echo "Backup aborted by user." >&2
                        exit 1
                        ;;
                esac
            else
                if [ "$BAT_PCT" -le 10 ]; then
                    echo "Error: Battery critically low (${BAT_PCT}%) in non-interactive run. Aborting (use --force to bypass)." >&2
                    exit 1
                fi
            fi
        fi
    fi
fi

# Smart scratch selection: Check /tmp vs /var/tmp if user did not specify -t
if [ "$CUSTOM_SCRATCH" -eq 0 ] && [ -z "$TMPDIR" ]; then
    TMP_FREE_KB=$(df -k /tmp 2>/dev/null | awk 'NR==2 {print $4}')
    VARTMP_FREE_KB=$(df -k /var/tmp 2>/dev/null | awk 'NR==2 {print $4}')
    [ -z "$TMP_FREE_KB" ] && TMP_FREE_KB=0
    [ -z "$VARTMP_FREE_KB" ] && VARTMP_FREE_KB=0

    # If /tmp has less than 1000MB (1024000KB) and /var/tmp has more space
    if [ "$TMP_FREE_KB" -lt 1024000 ] && [ "$VARTMP_FREE_KB" -gt "$TMP_FREE_KB" ]; then
        SCRATCH_DIR="/var/tmp"
        log_info "Notice: Staging in /var/tmp ($((VARTMP_FREE_KB / 1024))MB free vs $((TMP_FREE_KB / 1024))MB in /tmp)."
    fi
fi

# Pre-flight check: Verify disk space in scratch directory and destination directory
check_disk_space() {
    target_path="$1"
    min_mb="${2:-500}"
    avail_kb=$(df -k "$target_path" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "$avail_kb" ]; then
        avail_mb=$((avail_kb / 1024))
        if [ "$avail_mb" -lt "$min_mb" ]; then
            if [ "$FORCE" -eq 1 ]; then
                log_warn "Warning: Low disk space on ${target_path} (${avail_mb}MB free, required >= ${min_mb}MB). Continuing due to --force."
            else
                echo "Error: Insufficient disk space on ${target_path} (${avail_mb}MB free, required >= ${min_mb}MB). Aborting (use --force to override)." >&2
                exit 1
            fi
        fi
    fi
}

# Compression formatting & RAM-safe tuning (piped natively for OpenBSD tar(1) compatibility)
PHYSMEM_BYTES=$(sysctl -n hw.physmem 2>/dev/null || echo 0)
case "$PHYSMEM_BYTES" in
    [0-9]*) ;;
    *) PHYSMEM_BYTES=0 ;;
esac

case "$COMPRESSOR" in
    xz)
        if ! command -v xz >/dev/null 2>&1; then
            echo "Error: XZ compression requested (-J/--xz) but 'xz' is not installed (pkg_add xz)." >&2
            exit 1
        fi
        EXT="tar.xz"
        # Bound XZ threads & memory to prevent OOM or hitting OpenBSD login.conf datasize limits
        if [ "$PHYSMEM_BYTES" -gt 0 ] && [ "$PHYSMEM_BYTES" -le 1073741824 ]; then
            export XZ_OPT="${XZ_OPT:--T1 -M 256M}"
            log_info "Notice: Low memory detected ($((PHYSMEM_BYTES / 1048576))MB). Restricting XZ: ${XZ_OPT}."
        elif [ "$PHYSMEM_BYTES" -gt 0 ] && [ "$PHYSMEM_BYTES" -le 4294967296 ]; then
            export XZ_OPT="${XZ_OPT:--T2 -M 40%}"
            log_info "Notice: Moderate memory detected ($((PHYSMEM_BYTES / 1048576))MB). Bounding XZ: ${XZ_OPT}."
        else
            export XZ_OPT="${XZ_OPT:--T0 -M 50%}"
        fi
        ;;
    zstd)
        if ! command -v zstd >/dev/null 2>&1; then
            echo "Error: Zstandard compression requested (-Z/--zstd) but 'zstd' is not installed (pkg_add zstd)." >&2
            exit 1
        fi
        EXT="tar.zst"
        ;;
    gzip)
        EXT="tar.gz"
        ;;
esac

if [ -n "$ENCRYPT_KEY" ]; then
    EXT="${EXT}.age"
fi

if [ "$VERBOSE" -eq 1 ]; then
    TAR_CREATE_OPTS="-cvf"
else
    TAR_CREATE_OPTS="-cf"
fi

# Resolve destination directory and archive filename
if [ -n "$CUSTOM_OUTPUT" ]; then
    FINAL_ARCHIVE_PATH="$CUSTOM_OUTPUT"
    FINAL_DEST_DIR="${CUSTOM_OUTPUT%/*}"
    [ "$FINAL_DEST_DIR" = "$CUSTOM_OUTPUT" ] && FINAL_DEST_DIR="."
    ARCHIVE_BASENAME="${CUSTOM_OUTPUT##*/}"
    if [ ! -d "$FINAL_DEST_DIR" ]; then
        echo "Error: Output directory '$FINAL_DEST_DIR' does not exist." >&2
        exit 1
    fi
else
    if [ -n "$DEST_DIR" ]; then
        FINAL_DEST_DIR="$DEST_DIR"
    else
        FINAL_DEST_DIR="$USER_HOME"
    fi

    if [ ! -d "$FINAL_DEST_DIR" ]; then
        echo "Error: Destination directory '$FINAL_DEST_DIR' does not exist." >&2
        exit 1
    fi

    ARCHIVE_BASENAME="${HOSTNAME}_${PROFILE}_backup_${TIMESTAMP}.${EXT}"
    FINAL_ARCHIVE_PATH="${FINAL_DEST_DIR}/${ARCHIVE_BASENAME}"
fi

# Pre-flight check: OpenBSD root slice warning & destination disk space
DEST_FS=$(df -P "$FINAL_DEST_DIR" 2>/dev/null | awk 'NR==2 {print $6}')
if [ "$DEST_FS" = "/" ]; then
    log_warn "Warning: Destination directory '$FINAL_DEST_DIR' is on the root filesystem (/)."
    log_warn "         OpenBSD root slices are typically small (1-2GB). Ensure sufficient space or use -d on /home or /mnt."
fi
check_disk_space "${FINAL_DEST_DIR}" 1000
check_disk_space "${SCRATCH_DIR}" 100

# Stage temporary archive directly in destination filesystem
# Prevents exhausting small OpenBSD /tmp (500MB-1GB) or /var/tmp partitions,
# and enables instantaneous atomic rename without cross-device data copying.
TMP_BACKUP_FILE=$(mktemp "${FINAL_DEST_DIR}/.${ARCHIVE_BASENAME}.tmp.XXXXXXXXXX")
SYSINFO_STAGE_DIR=$(mktemp -d "${SCRATCH_DIR}/openbsd_sysinfo.XXXXXXXXXX")
SYSINFO_DIR="${SYSINFO_STAGE_DIR}/_sysinfo"
mkdir -m 700 "${SYSINFO_DIR}"
TAR_ERR_FILE=$(mktemp "${SCRATCH_DIR}/openbsd_tar_err.XXXXXXXXXX")
TAR_STATUS_FILE=$(mktemp "${SCRATCH_DIR}/openbsd_tar_status.XXXXXXXXXX")
COMP_STATUS_FILE=$(mktemp "${SCRATCH_DIR}/openbsd_comp_status.XXXXXXXXXX")

# ==============================================================================
# 1. Target Directory Assembly
# ==============================================================================

# Core base targets for all profiles (verified to exist on filesystem)
# Note: /var/backups is intentionally omitted because it mirrors /etc/security
# shadow copies (master.passwd.current, etc_ssh_*) and is a common -d target.
set -A BASE_TARGETS etc root usr/local/bin usr/local/sbin var/cron/tabs var/cron/atjobs
set -A TARGETS
for b_tgt in "${BASE_TARGETS[@]}"; do
    [ -d "/${b_tgt}" ] && set -A TARGETS -- "${TARGETS[@]}" "$b_tgt"
done

if [ "$PROFILE" = "config" ]; then
    log_info "Mode: Configuration & Dotfile backup (fast disaster recovery)"
    # Collect all dotfiles and user configurations across /home
    for user_dir in /home/*; do
        if [ -d "$user_dir" ] && [ ! -L "$user_dir" ]; then
            u_rel="${user_dir#/}"
            for dotitem in \
                .config .local/bin bin \
                .xsession .xinitrc .Xdefaults .Xresources .xprofile \
                .cwmrc .conkyrc .fvwmrc .dwm .i3 .sway \
                .profile .kshrc .cshrc .login .zshrc .bashrc .tmux.conf \
                .ssh .gnupg .password-store \
                .vim .vimrc .emacs.d .neovim .gitconfig .cvsrc \
                .fonts .themes .icons .mail .mailrc .mutt .neomutt .newsboat; do
                if [ -e "${user_dir}/${dotitem}" ]; then
                    set -A TARGETS -- "${TARGETS[@]}" "${u_rel}/${dotitem}"
                fi
            done
        fi
    done
elif [ "$PROFILE" = "desktop" ]; then
    log_info "Mode: Desktop Workstation backup"
    set -A TARGETS -- "${TARGETS[@]}" home
    [ -d "/usr/local/share/fonts" ] && set -A TARGETS -- "${TARGETS[@]}" usr/local/share/fonts
elif [ "$PROFILE" = "laptop" ]; then
    log_info "Mode: Laptop / Mobile Notebook backup"
    set -A TARGETS -- "${TARGETS[@]}" home
    [ -d "/usr/local/share/fonts" ] && set -A TARGETS -- "${TARGETS[@]}" usr/local/share/fonts
elif [ "$PROFILE" = "server" ]; then
    log_info "Mode: Bare-metal Physical Server / SBC backup"
    set -A TARGETS -- "${TARGETS[@]}" home
    # Chroot daemons & server spools common on OpenBSD servers
    # (etc/wireguard and etc/cloud are already included under 'etc')
    [ -d "/var/unbound" ]     && set -A TARGETS -- "${TARGETS[@]}" var/unbound
    [ -d "/var/named" ]       && set -A TARGETS -- "${TARGETS[@]}" var/named
    [ -d "/var/nsd" ]         && set -A TARGETS -- "${TARGETS[@]}" var/nsd
    [ -d "/var/mail" ]        && set -A TARGETS -- "${TARGETS[@]}" var/mail
    [ -d "/var/spool/smtpd" ] && set -A TARGETS -- "${TARGETS[@]}" var/spool/smtpd
    [ -d "/var/vmail" ]       && set -A TARGETS -- "${TARGETS[@]}" var/vmail
    [ -d "/var/db/dhcpd" ]    && set -A TARGETS -- "${TARGETS[@]}" var/db/dhcpd

    if [ "$BACKUP_WEB" -eq 1 ] && [ -d "/var/www" ]; then
        log_info "Including web server files (/var/www)..."
        set -A TARGETS -- "${TARGETS[@]}" var/www
    fi
elif [ "$PROFILE" = "vps" ]; then
    log_info "Mode: Cloud VPS / Virtual Server backup"
    set -A TARGETS -- "${TARGETS[@]}" home
    [ -d "/var/unbound" ]   && set -A TARGETS -- "${TARGETS[@]}" var/unbound
    [ -d "/var/nsd" ]       && set -A TARGETS -- "${TARGETS[@]}" var/nsd

    if [ "$BACKUP_WEB" -eq 1 ] && [ -d "/var/www" ]; then
        log_info "Including web server files (/var/www)..."
        set -A TARGETS -- "${TARGETS[@]}" var/www
    fi
fi

# ==============================================================================
# 2. Exclusion Rules
# ==============================================================================
# In OpenBSD, tar(1) and pax(1) do not support GNU --exclude.
# Exclusions are implemented natively via '-s replstr' (ed(1) basic regular expressions).
# Member names that substitute to the empty string are not selected and will be skipped.
set -A TAR_EXCLUDES

add_exclude_rule() {
    typeset pat="$1"
    [ -z "$pat" ] && return 0
    typeset delim=","
    if [[ "$pat" == *","* ]]; then
        delim="@"
        if [[ "$pat" == *"@"* ]]; then
            delim=":"
            if [[ "$pat" == *":"* ]]; then
                delim="|"
            fi
        fi
    fi
    set -A TAR_EXCLUDES -- "${TAR_EXCLUDES[@]}" -s "${delim}${pat}${delim}${delim}"
}

add_exclude_dir() {
    typeset dir="$1"
    typeset esc
    esc=$(regex_escape "$dir")
    add_exclude_rule "^${esc}\$"
    add_exclude_rule "^${esc}/.*"
    add_exclude_rule ".*/${esc}\$"
    add_exclude_rule ".*/${esc}/.*"
}

add_exclude_file() {
    typeset f="$1"
    typeset esc
    esc=$(glob_to_bre "$f")
    add_exclude_rule "^${esc}\$"
    add_exclude_rule ".*/${esc}\$"
}

add_user_exclude() {
    typeset raw="$1"
    typeset esc base
    [ -z "$raw" ] && return 0
    raw="${raw#./}"
    raw="${raw#/}"
    if [[ "$raw" == */\* ]]; then
        base="${raw%/\*}"
        esc=$(glob_to_bre "$base")
        add_exclude_rule "^${esc}\$"
        add_exclude_rule "^${esc}/.*"
        add_exclude_rule ".*/${esc}\$"
        add_exclude_rule ".*/${esc}/.*"
    elif [[ "$raw" == */ ]]; then
        base="${raw%/}"
        esc=$(glob_to_bre "$base")
        add_exclude_rule "^${esc}\$"
        add_exclude_rule "^${esc}/.*"
        add_exclude_rule ".*/${esc}\$"
        add_exclude_rule ".*/${esc}/.*"
    elif [[ "$raw" == \*\*/* ]]; then
        base="${raw#\*\*/}"
        esc=$(glob_to_bre "$base")
        add_exclude_rule "^${esc}\$"
        add_exclude_rule "^${esc}/.*"
        add_exclude_rule ".*/${esc}\$"
        add_exclude_rule ".*/${esc}/.*"
    elif [[ "$raw" == \*/\* ]] || [[ "$raw" == \*/* ]]; then
        base="${raw#\*/}"
        esc=$(glob_to_bre "$base")
        add_exclude_rule "^${esc}\$"
        add_exclude_rule "^${esc}/.*"
        add_exclude_rule ".*/${esc}\$"
        add_exclude_rule ".*/${esc}/.*"
    elif [[ "$raw" == */* ]]; then
        # Explicit relative path (e.g., home/user/Videos or var/www/cache)
        esc=$(glob_to_bre "$raw")
        add_exclude_rule "^${esc}\$"
        add_exclude_rule "^${esc}/.*"
        add_exclude_rule ".*/${esc}\$"
        add_exclude_rule ".*/${esc}/.*"
    elif [[ "$raw" == *\*.* ]] || [[ "$raw" == *\.* ]]; then
        # Filename or extension glob (e.g., *.iso, *.log, file.db) anchored at end
        esc=$(glob_to_bre "$raw")
        add_exclude_rule "^${esc}\$"
        add_exclude_rule ".*/${esc}\$"
    else
        # Generic directory or file basename
        esc=$(glob_to_bre "$raw")
        add_exclude_rule "^${esc}\$"
        add_exclude_rule "^${esc}/.*"
        add_exclude_rule ".*/${esc}\$"
        add_exclude_rule ".*/${esc}/.*"
    fi
}

# Security & Secrets Protection (when --skip-secrets is active or on config profile)
if [ "$SKIP_SECRETS" -eq 1 ]; then
    log_info "Applying security exclusions (--skip-secrets active)..."
    # Defense-in-depth: never include /var/backups shadow copies when skipping secrets
    add_exclude_rule "^var/backups\$"
    add_exclude_rule "^var/backups/.*"

    # System credential hashes and shadow files (preserve /etc/passwd for UID/GID mapping)
    add_exclude_rule "^etc/master\.passwd\$"
    add_exclude_rule ".*/etc/master\.passwd\$"
    add_exclude_rule "^etc/spwd\.db\$"
    add_exclude_rule ".*/etc/spwd\.db\$"
    add_exclude_rule "^etc/shadow\$"
    add_exclude_rule ".*/etc/shadow\$"
    add_exclude_rule "^etc/skey\$"
    add_exclude_rule "^etc/skey/.*"
    add_exclude_rule ".*/etc/skey\$"
    add_exclude_rule ".*/etc/skey/.*"

    # SSH host private keys (preserve public .pub keys)
    add_exclude_rule "^etc/ssh/ssh_host_.*_key\$"
    add_exclude_rule ".*/etc/ssh/ssh_host_.*_key\$"

    # Signing, TLS, ACME, VPN, Mail, and Interface Credentials (Wi-Fi wpakey / WireGuard wgkey)
    add_exclude_rule "^etc/signify/.*\.sec\$"
    add_exclude_rule ".*/etc/signify/.*\.sec\$"
    add_exclude_rule "^etc/age/.*\.key\$"
    add_exclude_rule "^etc/age/backup\.sec\$"
    add_exclude_rule "^etc/ssl/private/.*"
    add_exclude_rule "^etc/ssl/private\$"
    add_exclude_rule ".*/etc/ssl/private/.*"
    add_exclude_rule ".*/etc/ssl/private\$"
    add_exclude_rule "^etc/acme/.*"
    add_exclude_rule "^etc/acme\$"
    add_exclude_rule "^etc/iked/private/.*"
    add_exclude_rule "^etc/iked/private\$"
    add_exclude_rule "^etc/isakmpd/private/.*"
    add_exclude_rule "^etc/isakmpd/private\$"
    add_exclude_rule "^etc/wireguard/.*\.key\$"
    add_exclude_rule ".*/etc/wireguard/.*\.key\$"
    add_exclude_rule "^etc/ipsec\.secrets\$"
    add_exclude_rule ".*/etc/ipsec\.secrets\$"
    add_exclude_rule "^etc/hostname\..*"
    add_exclude_rule "^etc/mail/secrets\$"
    add_exclude_rule "^etc/mail/dkim\$"
    add_exclude_rule "^etc/mail/dkim/.*"

    # User private SSH keys (preserve id_*.pub and authorized_keys!)
    add_exclude_rule ".*\.ssh/id_rsa\$"
    add_exclude_rule ".*\.ssh/id_dsa\$"
    add_exclude_rule ".*\.ssh/id_ecdsa\$"
    add_exclude_rule ".*\.ssh/id_ecdsa_sk\$"
    add_exclude_rule ".*\.ssh/id_ed25519\$"
    add_exclude_rule ".*\.ssh/id_ed25519_sk\$"
    add_exclude_rule ".*\.ssh/identity\$"
    add_exclude_rule ".*\.ssh/.*\.pem\$"
    add_exclude_rule ".*\.ssh/.*\.key\$"

    # GPG secret keys, password stores, cloud/DB/git creds, session cookies, histories
    add_exclude_rule ".*\.gnupg/private-keys-v1\.d/.*"
    add_exclude_rule ".*\.gnupg/secring\.gpg\$"
    add_exclude_rule ".*\.password-store/.*"
    add_exclude_rule ".*\.netrc\$"
    add_exclude_rule ".*\.git-credentials\$"
    add_exclude_rule ".*\.my\.cnf\$"
    add_exclude_rule ".*\.pgpass\$"
    add_exclude_rule ".*\.aws/.*"
    add_exclude_rule ".*\.kube/.*"
    add_exclude_rule ".*\.docker/config\.json\$"
    add_exclude_rule ".*\.ksh_history\$"
    add_exclude_rule ".*\.bash_history\$"
    add_exclude_rule ".*\.zsh_history\$"
    add_exclude_rule ".*\.history\$"
    add_exclude_rule ".*\.vim/undo/.*"
    add_exclude_rule ".*\.vim/undo\$"
    add_exclude_rule ".*\.viminfo\$"
    add_exclude_rule ".*\.Xauthority\$"
    add_exclude_rule ".*\.sndio/cookie\$"

    # Disable database dumps when skipping secrets
    BACKUP_MARIADB=0
    BACKUP_POSTGRES=0
    set -A SQLITE_DBS
fi

# Fundamental Loop & Recursion Protection (ALWAYS enforced to prevent corrupting archives)
# Specifically targets backup archives & staging files without dropping personal user tarballs!
add_exclude_rule ".*_backup_.*\.tar\..*"
add_exclude_rule ".*_backup_.*\.tgz.*"
add_exclude_rule ".*_backup_.*\.sha256.*"
add_exclude_rule ".*_backup_.*\.sig\$"
add_exclude_rule ".*/\..*_backup_.*\.tmp\..*"
add_exclude_rule "^var/backups/etc\.pre-restore\..*\.tar\.gz\$"

# Sockets (OpenBSD ustar cannot archive sockets; dynamic IPC sockets should never be backed up)
add_exclude_rule ".*\.gnupg/S\..*"
add_exclude_rule ".*\.sock\$"
add_exclude_rule ".*\.socket\$"

# Explicitly exclude the active output archive, temp file, and companion files
if [ -n "$FINAL_DEST_DIR" ]; then
    esc_base=$(regex_escape "$ARCHIVE_BASENAME")
    esc_tmp=$(regex_escape "${TMP_BACKUP_FILE##*/}")
    add_exclude_rule "^${esc_base}\$"
    add_exclude_rule ".*/${esc_base}\$"
    add_exclude_rule "^${esc_base}\.sha256.*"
    add_exclude_rule ".*/${esc_base}\.sha256.*"
    add_exclude_rule "^${esc_base}\.sig\$"
    add_exclude_rule ".*/${esc_base}\.sig\$"
    add_exclude_rule "^${esc_tmp}\$"
    add_exclude_rule ".*/${esc_tmp}\$"
fi

# Exclude foreign / network / memory filesystem mountpoints anchored to exact mount paths
# (Prevents e.g. mfs on /tmp from accidentally excluding unrelated */tmp/* directories)
mount 2>/dev/null | awk '$5 ~ /^(nfs|fuse|fusefs|mfs|tmpfs|smbfs)$/ {print $3}' | while IFS= read -r mnt_entry; do
    rel_mnt="${mnt_entry#/}"
    if [ -n "$rel_mnt" ]; then
        esc_mnt=$(regex_escape "$rel_mnt")
        echo "^${esc_mnt}\$"
        echo "^${esc_mnt}/.*"
    fi
done > "${SYSINFO_STAGE_DIR}/.mnt_excludes"
while IFS= read -r mnt_pat; do
    [ -n "$mnt_pat" ] && add_exclude_rule "$mnt_pat"
done < "${SYSINFO_STAGE_DIR}/.mnt_excludes"
rm -f "${SYSINFO_STAGE_DIR}/.mnt_excludes"

if [ "$NO_EXCLUDES" -eq 0 ]; then
    if [ "$INCLUDE_CACHES" -eq 0 ]; then
        add_exclude_dir ".cache"
        add_exclude_dir ".thumbnails"
        add_exclude_dir ".local/share/Trash"
        # Firefox caches only (preserve storage/default so extension settings survive restore)
        add_exclude_rule ".*/\.mozilla/firefox/[^/]*/cache2\$"
        add_exclude_rule ".*/\.mozilla/firefox/[^/]*/cache2/.*"
        add_exclude_rule ".*/\.mozilla/firefox/[^/]*/startupCache\$"
        add_exclude_rule ".*/\.mozilla/firefox/[^/]*/startupCache/.*"
        add_exclude_rule ".*/\.mozilla/firefox/[^/]*/shader-cache\$"
        add_exclude_rule ".*/\.mozilla/firefox/[^/]*/shader-cache/.*"
        add_exclude_rule ".*/\.mozilla/firefox/[^/]*/storage/temporary\$"
        add_exclude_rule ".*/\.mozilla/firefox/[^/]*/storage/temporary/.*"
        add_exclude_rule ".*/\.config/google-chrome/[^/]*Cache.*"
        add_exclude_rule ".*/\.config/chromium/[^/]*Cache.*"
        add_exclude_dir ".cargo/registry"
        add_exclude_dir ".cargo/git"
        add_exclude_dir "go/pkg/mod/cache"
        add_exclude_dir ".gradle/caches"
        add_exclude_dir ".m2/repository"
        add_exclude_dir ".venv"
        add_exclude_dir "venv"
        add_exclude_dir "Code Cache"
        add_exclude_dir "GPUCache"
        add_exclude_dir "node_modules"
        add_exclude_dir "target/debug"
        add_exclude_dir "target/release"
        add_exclude_dir "__pycache__"
        add_exclude_dir ".pytest_cache"
        add_exclude_file "*.core"
        add_exclude_file "*.swp"
        add_exclude_file "recently-used.xbel"
    fi

    if [ "$INCLUDE_DOWNLOADS" -eq 0 ] && [[ "$PROFILE" == "desktop" || "$PROFILE" == "laptop" ]]; then
        add_exclude_dir "Downloads"
        add_exclude_dir "downloads"
    fi
fi

for pat in "${USER_EXCLUDES[@]}"; do
    add_user_exclude "$pat"
done

if [ -n "$EXCLUDE_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) continue ;;
            *) add_user_exclude "$line" ;;
        esac
    done < "$EXCLUDE_FILE"
fi

# ==============================================================================
# 3. Database Dumps (Optional)
# ==============================================================================
if [ "$BACKUP_MARIADB" -eq 1 ]; then
    log_info "Capturing MariaDB database dump (compressed)..."
    if command -v mysqldump >/dev/null 2>&1; then
        if [ -t 0 ]; then
            echo -n "Enter MariaDB root password (leave blank for unix socket auth): "
            SAVED_STTY=$(stty -g)
            trap 'stty "${SAVED_STTY}"; echo; exit 1' INT TERM QUIT
            stty -echo
            read DB_PASS
            stty "${SAVED_STTY}"
            trap cleanup EXIT INT TERM QUIT
            echo
            [ -n "$DB_PASS" ] && export MYSQL_PWD="$DB_PASS"
        fi
        DB_ERR_FILE="${SYSINFO_STAGE_DIR}/.mariadb.err"
        if mysqldump -u root --all-databases --single-transaction --routines --events 2>"${DB_ERR_FILE}" \
            | gzip -c > "${SYSINFO_DIR}/mariadb_all_databases.sql.gz"; then
            gz_bytes=$(wc -c < "${SYSINFO_DIR}/mariadb_all_databases.sql.gz" 2>/dev/null || echo 0)
            if [ "$gz_bytes" -lt 50 ]; then
                rm -f "${SYSINFO_DIR}/mariadb_all_databases.sql.gz"
                log_warn "Error: MariaDB dump produced no data."
                [ -s "${DB_ERR_FILE}" ] && cat "${DB_ERR_FILE}" >&2
                BACKUP_HAD_ERROR=1
            fi
        else
            rm -f "${SYSINFO_DIR}/mariadb_all_databases.sql.gz"
            log_warn "Error: MariaDB dump failed."
            [ -s "${DB_ERR_FILE}" ] && cat "${DB_ERR_FILE}" >&2
            BACKUP_HAD_ERROR=1
        fi
        rm -f "${DB_ERR_FILE}"
        unset MYSQL_PWD DB_PASS
    else
        log_warn "Error: mysqldump command not found (requested via --mariadb)."
        BACKUP_HAD_ERROR=1
    fi
fi

if [ "$BACKUP_POSTGRES" -eq 1 ]; then
    log_info "Capturing PostgreSQL database dump (compressed)..."
    PG_DUMPALL=$(command -v pg_dumpall 2>/dev/null || true)
    [ -z "$PG_DUMPALL" ] && [ -x "/usr/local/bin/pg_dumpall" ] && PG_DUMPALL="/usr/local/bin/pg_dumpall"
    if [ -n "$PG_DUMPALL" ]; then
        DB_ERR_FILE="${SYSINFO_STAGE_DIR}/.postgres.err"
        if su -l _postgresql -c "${PG_DUMPALL}" 2>"${DB_ERR_FILE}" \
            | gzip -c > "${SYSINFO_DIR}/postgresql_all_databases.sql.gz"; then
            gz_bytes=$(wc -c < "${SYSINFO_DIR}/postgresql_all_databases.sql.gz" 2>/dev/null || echo 0)
            if [ "$gz_bytes" -lt 50 ]; then
                rm -f "${SYSINFO_DIR}/postgresql_all_databases.sql.gz"
                log_warn "Error: PostgreSQL dump produced no data."
                [ -s "${DB_ERR_FILE}" ] && cat "${DB_ERR_FILE}" >&2
                BACKUP_HAD_ERROR=1
            fi
        else
            rm -f "${SYSINFO_DIR}/postgresql_all_databases.sql.gz"
            log_warn "Error: PostgreSQL dump failed."
            [ -s "${DB_ERR_FILE}" ] && cat "${DB_ERR_FILE}" >&2
            BACKUP_HAD_ERROR=1
        fi
        rm -f "${DB_ERR_FILE}"
    else
        log_warn "Error: pg_dumpall command not found (requested via --postgres)."
        BACKUP_HAD_ERROR=1
    fi
fi

if [ ${#SQLITE_DBS[@]} -gt 0 ]; then
    log_info "Snapshotting SQLite database(s) safely..."
    if command -v sqlite3 >/dev/null 2>&1; then
        mkdir -m 700 -p "${SYSINFO_DIR}/sqlite"
        for sqldb in "${SQLITE_DBS[@]}"; do
            safe_name=$(printf "%s" "${sqldb#/}" | tr '/' '_')
            out_db="${SYSINFO_DIR}/sqlite/${safe_name}"
            if ! sqlite3 "$sqldb" ".timeout 5000" ".backup '${out_db}'"; then
                log_warn "Error: Failed to snapshot SQLite database '${sqldb}'."
                rm -f "$out_db"
                BACKUP_HAD_ERROR=1
            fi
        done
    else
        log_warn "Error: sqlite3 command not found (requested via --sqlite)."
        BACKUP_HAD_ERROR=1
    fi
fi

# ==============================================================================
# 4. Comprehensive OpenBSD State & Metadata Capture
# ==============================================================================
log_info "Capturing OpenBSD system state and bare-metal metadata..."

# Manifest & System Information
cat <<EOF > "${SYSINFO_DIR}/backup_manifest.txt"
OpenBSD Backup Manifest
Generated    : $(date)
Hostname     : ${HOSTNAME}
Profile      : ${PROFILE}
Platform     : ${DETECTED_DETAIL}
OS Kernel    : $(uname -a)
OS Release   : $(uname -r)
Architecture : ${HW_MACHINE}
Compression  : ${COMPRESSOR}
Encrypted    : $([ -n "$ENCRYPT_KEY" ] && echo "yes (age)" || echo "no")
Secrets Skip : $([ "$SKIP_SECRETS" -eq 1 ] && echo "yes" || echo "no")
EOF

# Detailed Hardware & Environment Classification
cat <<HWEOF > "${SYSINFO_DIR}/hardware_type.txt"
Hardware & Environment Classification:
Classification : ${DETECTED_DETAIL}
Profile        : ${PROFILE}
Vendor         : $(sysctl -n hw.vendor 2>/dev/null || echo "Unknown")
Product        : $(sysctl -n hw.product 2>/dev/null || echo "Unknown")
Version        : $(sysctl -n hw.version 2>/dev/null || echo "Unknown")
UUID           : $(sysctl -n hw.uuid 2>/dev/null || echo "Unknown")
CPU Model      : $(sysctl -n hw.model 2>/dev/null || echo "Unknown")
CPU Cores      : $(sysctl -n hw.ncpusfound 2>/dev/null || echo "Unknown") (online: $(sysctl -n hw.ncpus 2>/dev/null || echo "Unknown"))
Physical RAM   : $(( PHYSMEM_BYTES / 1048576 )) MB
Disks (hw)     : $(sysctl -n hw.disknames 2>/dev/null || echo "Unknown")
HWEOF

pkg_info -mz > "${SYSINFO_DIR}/installed_packages.txt" 2>/dev/null || true
pkg_info > "${SYSINFO_DIR}/installed_packages_full.txt" 2>/dev/null || true
rcctl ls on > "${SYSINFO_DIR}/services_enabled_rcctl.txt" 2>/dev/null || true
rcctl ls started > "${SYSINFO_DIR}/services_started_rcctl.txt" 2>/dev/null || true
command -v rcctl >/dev/null 2>&1 && rcctl get all > "${SYSINFO_DIR}/services_all_flags.txt" 2>/dev/null || true
[ -f /etc/rc.conf.local ] && cp /etc/rc.conf.local "${SYSINFO_DIR}/rc.conf.local" 2>/dev/null || true

# Storage, Disks, Mounts, and DUIDs
echo "# Disk DUID and Mount Points" > "${SYSINFO_DIR}/duids.txt"
sysctl -n hw.disknames 2>/dev/null >> "${SYSINFO_DIR}/duids.txt" || true
echo "" >> "${SYSINFO_DIR}/duids.txt"
cat /etc/fstab >> "${SYSINFO_DIR}/duids.txt" 2>/dev/null || true

mount -v > "${SYSINFO_DIR}/mounts.txt" 2>/dev/null || true
command -v swapctl >/dev/null 2>&1 && swapctl -l > "${SYSINFO_DIR}/swap.txt" 2>/dev/null || true

# Extract disks: handles sd, wd, nvme, and vioblk
for disk in $(sysctl -n hw.disknames 2>/dev/null | tr ',' '\n' | cut -d: -f1); do
    if [ -n "$disk" ]; then
        disklabel "$disk" > "${SYSINFO_DIR}/disklabel_${disk}.txt" 2>/dev/null || true
        fdisk "$disk" > "${SYSINFO_DIR}/fdisk_${disk}.txt" 2>/dev/null || true
        [ -s "${SYSINFO_DIR}/disklabel_${disk}.txt" ] || rm -f "${SYSINFO_DIR}/disklabel_${disk}.txt"
        [ -s "${SYSINFO_DIR}/fdisk_${disk}.txt" ] || rm -f "${SYSINFO_DIR}/fdisk_${disk}.txt"
    fi
done

# Raspberry Pi / ARM MSDOS Boot Partition Capture (config.txt, cmdline.txt, firmware listing)
if [ "$IS_RPI" -eq 1 ] || [[ "$HW_MACHINE" == "arm64" || "$HW_MACHINE" == "armv7" ]]; then
    ROOT_DEV=$(df -P / 2>/dev/null | awk 'NR==2 {print $1}')
    ROOT_DISK="${ROOT_DEV#/dev/}"
    ROOT_DISK="${ROOT_DISK%[a-p]}"
    if [ -n "$ROOT_DISK" ] && [ -f "${SYSINFO_DIR}/disklabel_${ROOT_DISK}.txt" ]; then
        MSDOS_PART=$(awk '$4 == "MSDOS" {gsub(/:/, "", $1); print $1; exit}' "${SYSINFO_DIR}/disklabel_${ROOT_DISK}.txt")
        if [ -n "$MSDOS_PART" ] && [ -b "/dev/${ROOT_DISK}${MSDOS_PART}" ]; then
            EXISTING_MNT=$(mount 2>/dev/null | awk -v dev="/dev/${ROOT_DISK}${MSDOS_PART}" '$1 == dev {print $3; exit}')
            BOOT_SRC=""
            if [ -n "$EXISTING_MNT" ]; then
                BOOT_SRC="$EXISTING_MNT"
            else
                RPI_BOOT_MNT=$(mktemp -d "${SCRATCH_DIR}/openbsd_rpiboot.XXXXXXXXXX")
                if mount -t msdos -o ro "/dev/${ROOT_DISK}${MSDOS_PART}" "${RPI_BOOT_MNT}" 2>/dev/null; then
                    RPI_BOOT_MOUNTED=1
                    BOOT_SRC="${RPI_BOOT_MNT}"
                fi
            fi

            if [ -n "$BOOT_SRC" ]; then
                mkdir -m 700 -p "${SYSINFO_DIR}/rpi_boot"
                for bfile in config.txt cmdline.txt; do
                    [ -f "${BOOT_SRC}/${bfile}" ] && cp "${BOOT_SRC}/${bfile}" "${SYSINFO_DIR}/rpi_boot/${bfile}" 2>/dev/null || true
                done
                ls -laR "${BOOT_SRC}" > "${SYSINFO_DIR}/rpi_boot/boot_files_listing.txt" 2>/dev/null || true
            fi

            if [ "$RPI_BOOT_MOUNTED" -eq 1 ]; then
                umount "${RPI_BOOT_MNT}" 2>/dev/null || true
                RPI_BOOT_MOUNTED=0
                rmdir "${RPI_BOOT_MNT}" 2>/dev/null || true
                RPI_BOOT_MNT=""
            fi
        fi
    fi
fi

# Softraid / encrypted crypto volumes & Hardware RAID controllers
if command -v bioctl >/dev/null 2>&1; then
    for ctl in softraid0 mfi0 ami0 ciss0 mfii0; do
        if bioctl "$ctl" >/dev/null 2>&1; then
            echo "--- bioctl ${ctl} ---" >> "${SYSINFO_DIR}/bioctl_status.txt"
            bioctl "$ctl" >> "${SYSINFO_DIR}/bioctl_status.txt" 2>/dev/null || true
        fi
    done
    [ -s "${SYSINFO_DIR}/bioctl_status.txt" ] || rm -f "${SYSINFO_DIR}/bioctl_status.txt"

    # Softraid recreation helper documentation (OpenBSD uses 'softraid0', NOT 'sr0')
    if bioctl softraid0 >/dev/null 2>&1; then
        {
            echo "# Softraid Crypto Volume Reconstruction Helper"
            echo "# To recreate this encrypted volume on a replacement bare-metal drive:"
            echo "# 1. Initialize disklabel partition (type RAID, e.g. partition 'a'):"
            echo "#    disklabel -E <target_disk>"
            echo "# 2. Assemble softraid crypto container:"
            sr_chunks=$(bioctl softraid0 2>/dev/null | awk '/Chunk/ {print $NF}' | paste -sd ',' -)
            if [ -n "$sr_chunks" ]; then
                echo "#    bioctl -c C -l ${sr_chunks} softraid0"
            else
                echo "#    bioctl -c C -l <chunk_duid>.a softraid0"
            fi
            echo "# 3. Partition the new pseudo-device (e.g. sdX) and format a data partition (NEVER partition 'c'):"
            echo "#    disklabel -E sdX && newfs /dev/rsdXa && mount /dev/sdXa /mnt"
        } > "${SYSINFO_DIR}/softraid_recreate.txt" 2>/dev/null || true
    fi
fi

# System hardware sensors (thermals, fans, power supply, battery wear)
sysctl hw.sensors > "${SYSINFO_DIR}/sensors.txt" 2>/dev/null || true
[ -s "${SYSINFO_DIR}/sensors.txt" ] || rm -f "${SYSINFO_DIR}/sensors.txt"

# Bootloader and Console configuration
[ -f /etc/boot.conf ] && cp /etc/boot.conf "${SYSINFO_DIR}/boot.conf" 2>/dev/null || true
[ -f /etc/ttys ] && cp /etc/ttys "${SYSINFO_DIR}/ttys" 2>/dev/null || true

# Firmware status
if command -v fw_update >/dev/null 2>&1; then
    fw_update -n > "${SYSINFO_DIR}/firmware_status.txt" 2>/dev/null || true
fi

# Hardware & System settings
sysctl -a > "${SYSINFO_DIR}/sysctl.txt" 2>/dev/null || true
dmesg > "${SYSINFO_DIR}/dmesg.txt" 2>/dev/null || true

# Redact WireGuard/Wi-Fi secrets from ifconfig output when --skip-secrets is active
if [ "$SKIP_SECRETS" -eq 1 ]; then
    ifconfig -A 2>/dev/null | sed -E 's/(wgkey|wpakey|nwkey|wgpka)[[:space:]]+[^[:space:]]+/\1 <REDACTED>/g' > "${SYSINFO_DIR}/ifconfig.txt" || true
else
    ifconfig -A > "${SYSINFO_DIR}/ifconfig.txt" 2>/dev/null || true
fi

netstat -rn > "${SYSINFO_DIR}/routing_table.txt" 2>/dev/null || true
command -v route >/dev/null 2>&1 && route -n show > "${SYSINFO_DIR}/routing_table_detailed.txt" 2>/dev/null || true
command -v netstat >/dev/null 2>&1 && netstat -ni > "${SYSINFO_DIR}/netstat_interfaces.txt" 2>/dev/null || true
command -v arp >/dev/null 2>&1 && arp -an > "${SYSINFO_DIR}/arp_table.txt" 2>/dev/null || true
command -v ndp >/dev/null 2>&1 && ndp -an > "${SYSINFO_DIR}/ndp_table.txt" 2>/dev/null || true

# Firewall and packet filter rules (OpenBSD unified NAT/rdr into pfctl -sr)
if command -v pfctl >/dev/null 2>&1; then
    PF_RULES=$(pfctl -sr 2>/dev/null || true)
    PF_TABLES=$(pfctl -s Tables 2>/dev/null || true)
    PF_ANCHORS=$(pfctl -s Anchors -v 2>/dev/null || true)
    if [ -n "$PF_RULES" ] || [ -n "$PF_TABLES" ] || [ -n "$PF_ANCHORS" ]; then
        {
            [ -n "$PF_RULES" ] && printf "%s\n" "$PF_RULES"
            if [ -n "$PF_TABLES" ]; then
                echo "--- Active PF Tables ---"
                printf "%s\n" "$PF_TABLES"
            fi
            if [ -n "$PF_ANCHORS" ]; then
                echo "--- Active PF Anchors ---"
                printf "%s\n" "$PF_ANCHORS"
            fi
        } > "${SYSINFO_DIR}/pf_rules.txt"
    fi
fi

# Workstation & Desktop hardware state
if [[ "$PROFILE" == "desktop" || "$PROFILE" == "laptop" ]] || [ -n "$DISPLAY" ]; then
    command -v wsconsctl >/dev/null 2>&1 && wsconsctl -a > "${SYSINFO_DIR}/wsconsctl_state.txt" 2>/dev/null || true
    command -v sndioctl >/dev/null 2>&1 && sndioctl > "${SYSINFO_DIR}/sndioctl_state.txt" 2>/dev/null || true
    command -v mixerctl >/dev/null 2>&1 && mixerctl -a > "${SYSINFO_DIR}/mixerctl_state.txt" 2>/dev/null || true
    command -v audioctl >/dev/null 2>&1 && audioctl -a > "${SYSINFO_DIR}/audioctl_state.txt" 2>/dev/null || true

    if [ -n "$FINAL_USER" ] && [ -n "$DISPLAY" ]; then
        ESC_DISP=$(shell_escape "$DISPLAY")
        ESC_XAUTH=$(shell_escape "${XAUTHORITY:-${USER_HOME}/.Xauthority}")
        # Do NOT use 'su -l', which wipes DISPLAY and XAUTHORITY
        su "$FINAL_USER" -c "DISPLAY='${ESC_DISP}' XAUTHORITY='${ESC_XAUTH}' xrandr --verbose" \
            > "${SYSINFO_DIR}/xrandr_modes.txt" 2>/dev/null || true
        [ -s "${SYSINFO_DIR}/xrandr_modes.txt" ] || rm -f "${SYSINFO_DIR}/xrandr_modes.txt"
    fi
fi

# Laptop-specific power, touchpad, and wireless state
if [ "$PROFILE" = "laptop" ] || [ "$IS_LAPTOP" -eq 1 ]; then
    if command -v apm >/dev/null 2>&1; then
        {
            echo "APM Status:"
            apm 2>/dev/null || true
            echo "AC Status Code    : $(apm -a 2>/dev/null || true)"
            echo "Battery Status Code: $(apm -b 2>/dev/null || true)"
            echo "Battery Percentage: $(apm -l 2>/dev/null || true)%"
            echo "Battery Remaining : $(apm -m 2>/dev/null || true) min"
        } > "${SYSINFO_DIR}/apm_status.txt"
    fi

    if command -v wsconsctl >/dev/null 2>&1; then
        wsconsctl mouse > "${SYSINFO_DIR}/touchpad_state.txt" 2>/dev/null || true
        [ -s "${SYSINFO_DIR}/touchpad_state.txt" ] || rm -f "${SYSINFO_DIR}/touchpad_state.txt"
    fi

    {
        echo "CPU Performance Setting (hw.setperf): $(sysctl -n hw.setperf 2>/dev/null || echo N/A)"
        echo "CPU Speed (hw.cpuspeed)             : $(sysctl -n hw.cpuspeed 2>/dev/null || echo N/A) MHz"
        echo "Lid Suspend (machdep.lidsuspend)    : $(sysctl -n machdep.lidsuspend 2>/dev/null || echo N/A)"
        echo "Lid Action (machdep.lidaction)      : $(sysctl -n machdep.lidaction 2>/dev/null || echo N/A)"
    } > "${SYSINFO_DIR}/laptop_lid_power.txt"

    {
        echo "# Wireless Interfaces and Connection Status"
        for wif in $(ifconfig 2>/dev/null | awk -F: '/^[a-z]+[0-9]+:.*IEEE 802.11/ {print $1}'); do
            echo "=== Interface: ${wif} ==="
            if [ "$SKIP_SECRETS" -eq 1 ]; then
                ifconfig "$wif" 2>/dev/null | sed -E 's/(wpakey|nwkey)[[:space:]]+[^[:space:]]+/\1 <REDACTED>/g' || true
            else
                ifconfig "$wif" 2>/dev/null || true
            fi
            echo ""
        done
    } > "${SYSINFO_DIR}/wireless_interfaces.txt"
    [ -s "${SYSINFO_DIR}/wireless_interfaces.txt" ] || rm -f "${SYSINFO_DIR}/wireless_interfaces.txt"
fi

# Cloud VPS & Virtual Machine metadata
if [ "$PROFILE" = "vps" ] || [ "$IS_VM" -eq 1 ]; then
    {
        echo "# Cloud VPS / Virtual Machine Metadata"
        echo "Hypervisor / Provider : ${DETECTED_DETAIL}"
        echo "Vendor String         : ${HW_VENDOR}"
        echo "Product String        : ${HW_PRODUCT}"
        echo "Version String        : ${HW_VERSION}"
        if [ -f /etc/install.conf ]; then
            echo "Autoinstall Conf Found: /etc/install.conf"
        fi
        if [ -d /etc/cloud ]; then
            echo "Cloud-init Directory  : /etc/cloud (present)"
        fi
        echo ""
        echo "# VirtIO / Cloud Network Interfaces:"
        ifconfig -A 2>/dev/null | grep -E '^(vio|xnf|ena|vmx)[0-9]+:' || true
    } > "${SYSINFO_DIR}/cloud_metadata.txt"
fi

# Embed Turnkey Autonomous Recovery Script inside _sysinfo/
cat << 'RESCUE_EOF' > "${SYSINFO_DIR}/quick-restore.sh"
#!/bin/sh
# Autonomous Emergency Recovery Helper embedded in OpenBSD backup archive
set -e
set -o pipefail 2>/dev/null || true
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: Must be run as root." >&2
    exit 1
fi
echo "============================================================"
echo " OpenBSD Autonomous Emergency Restore Helper"
echo "============================================================"
SYSINFO_DIR="$(dirname "$0")"

echo "1. System Information:"
[ -f "${SYSINFO_DIR}/backup_manifest.txt" ] && cat "${SYSINFO_DIR}/backup_manifest.txt"
echo ""

if [ -f "${SYSINFO_DIR}/hardware_type.txt" ]; then
    echo "Hardware Classification:"
    grep -E '^(Classification|Profile|Vendor|Product|CPU|Physical)' "${SYSINFO_DIR}/hardware_type.txt" | sed 's/^/  /'
    echo ""
fi

if [ -f "${SYSINFO_DIR}/installed_packages.txt" ]; then
    pkg_count=$(wc -l < "${SYSINFO_DIR}/installed_packages.txt" | tr -d ' ')
    echo "Packages recorded in backup: ${pkg_count}"
    echo "To reinstall all recorded packages on a fresh install, run:"
    echo "  pkg_add -l ${SYSINFO_DIR}/installed_packages.txt"
    echo ""
fi

if [ -f "${SYSINFO_DIR}/services_enabled_rcctl.txt" ]; then
    echo "To re-enable services recorded in backup, run:"
    while read -r svc; do
        [ -n "$svc" ] && echo "  rcctl enable $svc"
    done < "${SYSINFO_DIR}/services_enabled_rcctl.txt"
    echo ""
fi

if [ -f "${SYSINFO_DIR}/firmware_status.txt" ]; then
    echo "To update firmware drivers, run:"
    echo "  fw_update"
    echo ""
fi

if [ -d "${SYSINFO_DIR}/rpi_boot" ]; then
    echo "Raspberry Pi / ARM Boot Partition Snapshot Captured:"
    ls -1 "${SYSINFO_DIR}/rpi_boot" | sed 's/^/  - /'
    echo "  Review config.txt and copy to the MSDOS boot partition (typically /dev/sd0i) if needed."
    echo ""
fi

ARCH_PROFILE=$(awk -F: '/^Profile/{gsub(/^[ \t]+/,"",$2); print $2}' "${SYSINFO_DIR}/backup_manifest.txt" 2>/dev/null || echo "")
if [ -n "$ARCH_PROFILE" ]; then
    echo "Disaster Recovery Guidance for Profile '${ARCH_PROFILE}':"
    case "$ARCH_PROFILE" in
        laptop)
            echo "  - Verify /etc/hostname.<wifi-if> for wireless credentials and SSID."
            echo "  - Check /etc/wsconsctl.conf for touchpad tapping and scrolling settings."
            echo "  - Ensure apmd is enabled: rcctl enable apmd && rcctl set apmd flags -A"
            ;;
        vps)
            echo "  - Verify /etc/boot.conf serial console: 'set tty com0' and /etc/ttys."
            echo "  - Ensure SSH host keys and authorized_keys are intact before rebooting."
            echo "  - Check /etc/hostname.vio0 (or virtual interface) for cloud networking."
            ;;
        server)
            echo "  - Review /etc/hostname.* for CARP, trunk, and VLAN interfaces."
            echo "  - Review bioctl_status.txt if rebuilding softraid or hardware RAID volumes."
            echo "  - Verify PF rules in /etc/pf.conf before bringing interfaces up."
            ;;
        desktop)
            echo "  - Review /etc/X11 and display manager (xenodm) settings."
            echo "  - Check sndioctl_state.txt, mixerctl_state.txt, and audioctl_state.txt."
            ;;
    esac
    echo ""
fi

if [ -f "${SYSINFO_DIR}/softraid_recreate.txt" ]; then
    echo "Softraid Rebuilding Guidance:"
    cat "${SYSINFO_DIR}/softraid_recreate.txt"
    echo ""
fi

for dl in "${SYSINFO_DIR}"/disklabel_*.txt; do
    if [ -f "$dl" ]; then
        disk_name="${dl##*disklabel_}"
        disk_name="${disk_name%.txt}"
        echo "To restore disk partition table on replacement drive (${disk_name}), run:"
        echo "  disklabel -R ${disk_name} ${dl}"
    fi
done
echo ""

if [ -f "${SYSINFO_DIR}/mariadb_all_databases.sql.gz" ]; then
    echo "To restore MariaDB database dump, run:"
    echo "  gunzip -c ${SYSINFO_DIR}/mariadb_all_databases.sql.gz | mysql -u root -p"
    echo ""
fi

if [ -f "${SYSINFO_DIR}/postgresql_all_databases.sql.gz" ]; then
    echo "To restore PostgreSQL database dump, run:"
    echo "  gunzip -c ${SYSINFO_DIR}/postgresql_all_databases.sql.gz | su -l _postgresql -c psql"
    echo ""
fi

if [ -d "${SYSINFO_DIR}/sqlite" ]; then
    echo "SQLite database snapshots available in ${SYSINFO_DIR}/sqlite/:"
    ls -1 "${SYSINFO_DIR}/sqlite" | sed 's/^/  - /'
    echo ""
fi

echo "IMPORTANT: When extracting onto a fresh OpenBSD install, exclude etc/fstab"
echo "so you do not overwrite the new disk's DUIDs, and run pwd_mkdb -p /etc/master.passwd"
echo "after restoring /etc/master.passwd:"
echo "  # gzip: gzip -dc <ARCHIVE> | tar -xpf - -s ',^etc/fstab$,,' -s ',^_sysinfo.*,,' -C /"
echo "  # xz  : xz -dc <ARCHIVE>   | tar -xpf - -s ',^etc/fstab$,,' -s ',^_sysinfo.*,,' -C /"
echo "  # zstd: zstd -dc <ARCHIVE> | tar -xpf - -s ',^etc/fstab$,,' -s ',^_sysinfo.*,,' -C /"
echo "  # age : age -d -i <KEY> <ARCHIVE.age> | <decompressor> | tar -xpf - ..."
echo "============================================================"
RESCUE_EOF
chmod 755 "${SYSINFO_DIR}/quick-restore.sh"

# ==============================================================================
# 5. Archive Creation & Validation
# ==============================================================================
log_info "Creating backup archive: ${FINAL_ARCHIVE_PATH}..."

run_compress_stream() {
    case "$COMPRESSOR" in
        gzip) gzip -c ;;
        xz)   xz -c ;;
        zstd) zstd -q -c ;;
    esac
}

run_compress_and_encrypt() {
    if [ -n "$ENCRYPT_KEY" ]; then
        run_compress_stream | age -R "${ENCRYPT_KEY}"
    else
        run_compress_stream
    fi
}

validate_unencrypted_archive() {
    typeset file="$1"
    case "$COMPRESSOR" in
        gzip) gzip -dc "$file" | tar -tf - >/dev/null 2>&1 ;;
        xz)   xz -dc "$file"   | tar -tf - >/dev/null 2>&1 ;;
        zstd) zstd -dc "$file" | tar -tf - >/dev/null 2>&1 ;;
    esac
}

# Stream tar -> compressor [-> age] directly to destination filesystem.
# Track tar and compressor/encryptor exit statuses separately so we never mask
# real I/O or permission errors while still tolerating benign live UNIX sockets.
set +e
(
    nice -n 15 tar ${TAR_CREATE_OPTS} - \
        "${TAR_EXCLUDES[@]}" \
        -C / "${TARGETS[@]}" \
        -C "${SYSINFO_STAGE_DIR}" _sysinfo \
        2> "${TAR_ERR_FILE}"
    echo $? > "${TAR_STATUS_FILE}"
) | (
    run_compress_and_encrypt > "${TMP_BACKUP_FILE}"
    echo $? > "${COMP_STATUS_FILE}"
)
set -e

TAR_EXIT=$(cat "${TAR_STATUS_FILE}" 2>/dev/null || echo 1)
COMP_EXIT=$(cat "${COMP_STATUS_FILE}" 2>/dev/null || echo 1)

if [ "$COMP_EXIT" -ne 0 ] || [ ! -s "${TMP_BACKUP_FILE}" ]; then
    [ -s "${TAR_ERR_FILE}" ] && cat "${TAR_ERR_FILE}" >&2
    echo "Error: Compression or encryption pipeline failed (exit code ${COMP_EXIT})." >&2
    syslog_msg err "Backup failed during compression/encryption (exit ${COMP_EXIT}) for ${FINAL_ARCHIVE_PATH}"
    exit 1
fi

if [ "$TAR_EXIT" -ne 0 ]; then
    # Filter out known benign live-socket/FIFO warnings; fail on ANY real read/permission/I/O error
    FATAL_TAR_ERRS=$(grep -viE 'socket ignored|Cannot archive socket|is a socket|file type not supported|removing leading' "${TAR_ERR_FILE}" || true)
    if [ -n "$FATAL_TAR_ERRS" ]; then
        echo "Error: tar encountered fatal error(s) (exit code ${TAR_EXIT}):" >&2
        printf "%s\n" "$FATAL_TAR_ERRS" >&2
        syslog_msg err "Backup failed: tar errors (exit ${TAR_EXIT}) for ${FINAL_ARCHIVE_PATH}"
        exit 1
    fi

    if [ -z "$ENCRYPT_KEY" ]; then
        log_info "Validating archive integrity after socket warnings..."
        if ! validate_unencrypted_archive "${TMP_BACKUP_FILE}"; then
            cat "${TAR_ERR_FILE}" >&2
            echo "Error: Archive failed integrity validation after tar warnings." >&2
            syslog_msg err "Backup failed archive validation for ${FINAL_ARCHIVE_PATH}"
            exit 1
        fi
    fi
    log_warn "Notice: Archive integrity verified. Non-fatal socket warnings encountered:"
    sed 's/^tar: /  - /' "${TAR_ERR_FILE}" >&2
fi

# Move archive into final destination atomically
mv "${TMP_BACKUP_FILE}" "${FINAL_ARCHIVE_PATH}"
TMP_BACKUP_FILE=""

# Generate BSD-tagged SHA256 checksum file alongside archive (compatible with signify -C)
log_info "Generating SHA256 checksum..."
if command -v sha256 >/dev/null 2>&1; then
    ( cd "${FINAL_DEST_DIR}" && sha256 "${ARCHIVE_BASENAME}" > "${ARCHIVE_BASENAME}.sha256" )
elif command -v sha256sum >/dev/null 2>&1; then
    (
        cd "${FINAL_DEST_DIR}"
        h=$(sha256sum "${ARCHIVE_BASENAME}" | awk '{print $1}')
        echo "SHA256 (${ARCHIVE_BASENAME}) = ${h}" > "${ARCHIVE_BASENAME}.sha256"
    )
elif command -v shasum >/dev/null 2>&1; then
    (
        cd "${FINAL_DEST_DIR}"
        h=$(shasum -a 256 "${ARCHIVE_BASENAME}" | awk '{print $1}')
        echo "SHA256 (${ARCHIVE_BASENAME}) = ${h}" > "${ARCHIVE_BASENAME}.sha256"
    )
fi

# Cryptographic signing via OpenBSD signify(1)
# Signs the tiny .sha256 manifest with an embedded signature (-e) so archives > 1 GiB
# never hit signify's 1 GiB maxmsgsize limit or exhaust RAM on small VPS/RPi hosts.
if [ -z "$SIGN_KEY" ] && [ -f "/etc/signify/backup.sec" ]; then
    SIGN_KEY="/etc/signify/backup.sec"
fi

SIG_OUTPUT_PATH=""
if [ -n "$SIGN_KEY" ]; then
    if command -v signify >/dev/null 2>&1; then
        log_info "Signing SHA256 manifest with OpenBSD signify (${SIGN_KEY})..."
        if ( cd "${FINAL_DEST_DIR}" && signify -S -e -s "$SIGN_KEY" -m "${ARCHIVE_BASENAME}.sha256" -x "${ARCHIVE_BASENAME}.sha256.sig" ); then
            SIG_OUTPUT_PATH="${FINAL_ARCHIVE_PATH}.sha256.sig"
            log_info "Archive manifest signed successfully: ${SIG_OUTPUT_PATH}"
        else
            echo "Error: signify signing failed!" >&2
            syslog_msg err "signify signing failed for ${FINAL_ARCHIVE_PATH}"
            exit 1
        fi
    else
        echo "Error: signify signing requested (${SIGN_KEY}) but signify command not found." >&2
        exit 1
    fi
fi

# Assign ownership to calling non-root user if run via doas/sudo
ARCHIVE_OWNED_BY_USER=0
if [ -n "$DOAS_USER" ] || [ -n "$SUDO_USER" ]; then
    if [ "$SKIP_SECRETS" -eq 1 ] || [ "$FORCE_CHOWN" -eq 1 ]; then
        chown "${FINAL_USER}" "${FINAL_ARCHIVE_PATH}" "${FINAL_ARCHIVE_PATH}.sha256" 2>/dev/null || true
        [ -n "$SIG_OUTPUT_PATH" ] && [ -f "$SIG_OUTPUT_PATH" ] && chown "${FINAL_USER}" "$SIG_OUTPUT_PATH" 2>/dev/null || true
        ARCHIVE_OWNED_BY_USER=1
    else
        log_info "Notice: Archive contains system credentials and private keys."
        log_info "        Ownership retained as root:wheel (0600) for security. Use --chown to override."
    fi
fi

# ==============================================================================
# 6. Retention & Pruning
# ==============================================================================
if [ "$KEEP_COUNT" -gt 0 ]; then
    if [ -n "$CUSTOM_OUTPUT" ]; then
        log_warn "Warning: --keep applies to standard '${HOSTNAME}_${PROFILE}_backup_*' filenames in '${FINAL_DEST_DIR}', not custom --output names."
    fi
    log_info "Applying retention policy (keeping last ${KEEP_COUNT} backups)..."
    ARCHIVE_PREFIX="${HOSTNAME}_${PROFILE}_backup_"

    # List actual archives only (including .tar.zst and .age) in chronological order (oldest first)
    set -A EXISTING_BACKUPS
    while IFS= read -r f || [ -n "$f" ]; do
        case "$f" in
            *.tar.gz|*.tar.xz|*.tar.zst|*.tgz|*.tar.gz.age|*.tar.xz.age|*.tar.zst.age|*.tgz.age)
                [ -f "$f" ] && set -A EXISTING_BACKUPS -- "${EXISTING_BACKUPS[@]}" "$f"
                ;;
        esac
    done <<EOF
$(ls -1tr \
    "${FINAL_DEST_DIR}/${ARCHIVE_PREFIX}"*.tar.gz \
    "${FINAL_DEST_DIR}/${ARCHIVE_PREFIX}"*.tar.xz \
    "${FINAL_DEST_DIR}/${ARCHIVE_PREFIX}"*.tar.zst \
    "${FINAL_DEST_DIR}/${ARCHIVE_PREFIX}"*.tgz \
    "${FINAL_DEST_DIR}/${ARCHIVE_PREFIX}"*.tar.gz.age \
    "${FINAL_DEST_DIR}/${ARCHIVE_PREFIX}"*.tar.xz.age \
    "${FINAL_DEST_DIR}/${ARCHIVE_PREFIX}"*.tar.zst.age \
    "${FINAL_DEST_DIR}/${ARCHIVE_PREFIX}"*.tgz.age \
    2>/dev/null || true)
EOF

    TOTAL_COUNT=${#EXISTING_BACKUPS[@]}

    if [ "$TOTAL_COUNT" -gt "$KEEP_COUNT" ]; then
        EXCESS=$((TOTAL_COUNT - KEEP_COUNT))
        i=0
        while [ "$i" -lt "$EXCESS" ]; do
            OLD_FILE="${EXISTING_BACKUPS[$i]}"
            if [ -f "$OLD_FILE" ]; then
                log_info "Pruning old archive: ${OLD_FILE##*/}"
                rm -f "$OLD_FILE" "${OLD_FILE}.sha256" "${OLD_FILE}.sha256.sig" "${OLD_FILE}.sig" 2>/dev/null || true
            fi
            i=$((i + 1))
        done
    fi
fi

# ==============================================================================
# 7. Remote Upload via SCP
# ==============================================================================
if [ -n "$UPLOAD_DEST" ]; then
    log_info "Uploading archive and checksum to ${UPLOAD_DEST}..."
    UPLOAD_SUCCESS=0

    set -A SCP_OPTS -q -o BatchMode=yes -o ConnectTimeout=30
    [ -n "$SSH_KEY" ] && set -A SCP_OPTS -- "${SCP_OPTS[@]}" -i "$SSH_KEY"

    set -A UPLOAD_FILES "${FINAL_ARCHIVE_PATH}" "${FINAL_ARCHIVE_PATH}.sha256"
    if [ -n "$SIG_OUTPUT_PATH" ] && [ -f "$SIG_OUTPUT_PATH" ]; then
        set -A UPLOAD_FILES -- "${UPLOAD_FILES[@]}" "$SIG_OUTPUT_PATH"
    fi

    # Only run scp as the invoking non-root user if they can actually read the archive
    # (when ARCHIVE_OWNED_BY_USER=0, the archive is root:wheel 0600, so scp must run as root).
    if [ "$ARCHIVE_OWNED_BY_USER" -eq 1 ] && [ -z "$SSH_KEY" ] && { [ -n "$DOAS_USER" ] || [ -n "$SUDO_USER" ]; }; then
        UPLOAD_USER="${DOAS_USER:-$SUDO_USER}"
        ESC_DEST=$(shell_escape "$UPLOAD_DEST")
        CMD_FILES=""
        for uf in "${UPLOAD_FILES[@]}"; do
            CMD_FILES="${CMD_FILES} '$(shell_escape "$uf")'"
        done
        AUTH_ENV=""
        if [ -n "$SSH_AUTH_SOCK" ]; then
            AUTH_ENV="SSH_AUTH_SOCK='$(shell_escape "$SSH_AUTH_SOCK")'"
        fi
        # Do NOT use 'su -l', which wipes SSH_AUTH_SOCK
        if su "$UPLOAD_USER" -c "${AUTH_ENV} scp -q -o BatchMode=yes -o ConnectTimeout=30 ${CMD_FILES} '${ESC_DEST}'"; then
            UPLOAD_SUCCESS=1
        fi
    else
        if scp "${SCP_OPTS[@]}" "${UPLOAD_FILES[@]}" "${UPLOAD_DEST}"; then
            UPLOAD_SUCCESS=1
        fi
    fi

    if [ "$UPLOAD_SUCCESS" -eq 1 ]; then
        log_info "Remote upload completed successfully!"
    else
        log_warn "Error: Remote upload to '${UPLOAD_DEST}' failed. Check SSH keys, permissions, and network."
        if [ "$ARCHIVE_OWNED_BY_USER" -eq 0 ] && { [ -n "$DOAS_USER" ] || [ -n "$SUDO_USER" ]; }; then
            log_warn "Hint: Archive is root-only (0600), so scp ran as root. Configure /root/.ssh or pass --ssh-key."
        fi
        BACKUP_HAD_ERROR=1
    fi
fi

# ==============================================================================
# 8. Desktop Notification
# ==============================================================================
ARCHIVE_SIZE=$(ls -lh "${FINAL_ARCHIVE_PATH}" | awk '{print $5}')
if [ "$SEND_NOTIFY" -eq 1 ] && [ -n "$FINAL_USER" ] && [ -n "$DISPLAY" ]; then
    NOTIFY_TITLE="OpenBSD Backup Complete"
    [ "$BACKUP_HAD_ERROR" -ne 0 ] && NOTIFY_TITLE="OpenBSD Backup Completed with Errors"
    NOTIFY_MSG="Archive: ${FINAL_ARCHIVE_PATH##*/}\nSize: ${ARCHIVE_SIZE}\nProfile: ${PROFILE}"
    ESC_TITLE=$(shell_escape "$NOTIFY_TITLE")
    ESC_MSG=$(shell_escape "$NOTIFY_MSG")
    ESC_BASE=$(shell_escape "${FINAL_ARCHIVE_PATH##*/}")
    ESC_DISP=$(shell_escape "$DISPLAY")
    ESC_XAUTH=$(shell_escape "${XAUTHORITY:-${USER_HOME}/.Xauthority}")
    DBUS_ENV=""
    [ -n "$DBUS_SESSION_BUS_ADDRESS" ] && DBUS_ENV="DBUS_SESSION_BUS_ADDRESS='$(shell_escape "$DBUS_SESSION_BUS_ADDRESS")'"

    if command -v notify-send >/dev/null 2>&1; then
        su "$FINAL_USER" -c "DISPLAY='${ESC_DISP}' XAUTHORITY='${ESC_XAUTH}' ${DBUS_ENV} notify-send -i drive-harddisk '${ESC_TITLE}' '${ESC_MSG}'" 2>/dev/null || true
    elif command -v xmessage >/dev/null 2>&1; then
        su "$FINAL_USER" -c "DISPLAY='${ESC_DISP}' XAUTHORITY='${ESC_XAUTH}' xmessage -center -buttons OK:0 '${ESC_TITLE}: ${ESC_BASE} (${ARCHIVE_SIZE})'" 2>/dev/null || true
    fi
fi

# ==============================================================================
# 9. Summary Report
# ==============================================================================
if [ "$QUIET" -eq 0 ]; then
    echo ""
    echo "============================================================"
    echo " OpenBSD Backup Summary"
    echo "============================================================"
    echo "Archive File : ${FINAL_ARCHIVE_PATH}"
    echo "SHA256 File  : ${FINAL_ARCHIVE_PATH}.sha256"
    [ -n "$SIG_OUTPUT_PATH" ] && echo "Signify Sig  : ${SIG_OUTPUT_PATH}"
    [ -n "$ENCRYPT_KEY" ] && echo "Encryption   : age (${ENCRYPT_KEY})"
    echo "Archive Size : ${ARCHIVE_SIZE}"
    echo "Profile Used : ${PROFILE}"
    echo "Environment  : ${DETECTED_DETAIL}"
    echo "Permissions  : $(ls -l "${FINAL_ARCHIVE_PATH}" | awk '{print $1, $3, $4}')"
    echo "Targets Captured:"
    for tgt in "${TARGETS[@]}"; do
        echo "  - /${tgt}"
    done
    echo "Metadata Captured:"
    for meta in "${SYSINFO_DIR}"/*; do
        [ -e "$meta" ] && echo "  - ${meta##*/}"
    done
    if [ "$NO_EXCLUDES" -eq 0 ]; then
        echo "Exclusions Applied:"
        [ "$INCLUDE_CACHES" -eq 0 ] && echo "  - Caches & build targets (.cache, Trash, Cargo/Node/Python)"
        [ "$INCLUDE_DOWNLOADS" -eq 0 ] && [[ "$PROFILE" == "desktop" || "$PROFILE" == "laptop" ]] && echo "  - ~/Downloads folder"
    fi
    echo "============================================================"
fi

if [ "$BACKUP_HAD_ERROR" -ne 0 ]; then
    echo "Backup finished with errors (see warnings above)." >&2
    syslog_msg err "Backup completed with errors: ${FINAL_ARCHIVE_PATH} (${ARCHIVE_SIZE})"
    exit 1
fi

syslog_msg info "Backup completed successfully: ${FINAL_ARCHIVE_PATH} (${ARCHIVE_SIZE}, profile=${PROFILE})"
log_info "Backup completed successfully!"
