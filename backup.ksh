#!/bin/ksh
# ==============================================================================
# backup.ksh
#
# Unified, robust, and profile-driven backup utility for OpenBSD.
# Protects system configurations, user customizations/dotfiles, service states,
# and bare-metal hardware metadata for fast and reliable disaster recovery.
#
# Profiles:
#   server  : Physical baremetal servers (hardware RAID/bioctl, sensors, bonded NICs,
#             PF rules, daemon chroots, web directories, databases).
#             Alias: baremetal, bare-metal.
#   desktop : Workstations (smart cache exclusions, multi-monitor xrandr, wsconsctl,
#             audio levels, desktop alerts). Alias: workstation.
#   laptop  : Laptops/notebooks (desktop features + battery safety checks, apm/apmd
#             state, touchpad wsconsctl, wireless network configs, display brightness).
#             Alias: notebook.
#   vps     : Cloud VPS & virtual machines (VirtIO devices, cloud-init, serial console,
#             memory-bounded compression, low-scratch awareness). Alias: cloud, vm.
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

# Enforce strict permissions from the very beginning (0600 files, 0700 dirs)
# Prevents sensitive private keys, shadow passwords, and DB dumps from exposure.
umask 077

PROGNAME="${0##*/}"
LOCK_DIR="/var/run/openbsd-backup.lock"
HOSTNAME=$(hostname)
TIMESTAMP=$(date '+%Y.%m.%d-%H.%M.%S')
SYSINFO_STAGE_DIR=""
SYSINFO_DIR=""
TAR_ERR_FILE=""
TMP_BACKUP_FILE=""

usage() {
    cat <<EOF
Usage: ${PROGNAME} [OPTIONS]

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
  -t, --temp-dir DIR        Temporary scratch directory (default: \$TMPDIR, /var/tmp, or /tmp)
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

Security, Signing & Ownership:
  -S, --sign KEY_FILE       Sign archive using OpenBSD signify(1) secret key
      --skip-secrets        Exclude credentials, hashes, private keys, and DB dumps
                            (enabled by default on 'config' profile)
      --chown               Allow assigning archive ownership to calling user
                            (permitted when --skip-secrets is active)
EOF
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
    # Check if existing lock is stale
    if [ -f "${LOCK_DIR}/pid" ]; then
        EXISTING_PID=$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)
        if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
            echo "Error: Another backup process is currently running (PID ${EXISTING_PID})." >&2
            exit 1
        else
            echo "Removing stale lock from PID ${EXISTING_PID}..."
            rm -rf "${LOCK_DIR}"
            mkdir "${LOCK_DIR}"
        fi
    else
        echo "Error: Lock directory ${LOCK_DIR} exists. Aborting." >&2
        exit 1
    fi
fi
echo "$$" > "${LOCK_DIR}/pid"

# Cleanup trap for lock directory and temporary files
cleanup() {
    EXIT_CODE=$?
    [ -n "${LOCK_DIR}" ] && rm -rf "${LOCK_DIR}" 2>/dev/null || true
    [ -n "${SYSINFO_STAGE_DIR}" ] && rm -rf "${SYSINFO_STAGE_DIR}" 2>/dev/null || true
    [ -n "${SYSINFO_DIR}" ] && rm -rf "${SYSINFO_DIR}" 2>/dev/null || true
    [ -n "${TAR_ERR_FILE}" ] && rm -f "${TAR_ERR_FILE}" 2>/dev/null || true
    [ -n "${TMP_BACKUP_FILE}" ] && rm -f "${TMP_BACKUP_FILE}" 2>/dev/null || true
    exit $EXIT_CODE
}
trap cleanup EXIT INT TERM QUIT

# Safe shell-escaping helper to prevent command injection in subshells
shell_escape() {
    typeset s="$1"
    printf "%s" "$s" | sed "s/'/'\\\\''/g"
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
KEEP_COUNT=0
USE_XZ=0
BACKUP_WEB=0
BACKUP_MARIADB=0
BACKUP_POSTGRES=0
INCLUDE_DOWNLOADS=0
INCLUDE_CACHES=0
NO_EXCLUDES=0
SEND_NOTIFY=0
VERBOSE=0
FORCE=0
SIGN_KEY=""
SKIP_SECRETS=0
FORCE_CHOWN=0
set -A USER_EXCLUDES
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
            USE_XZ=1
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
        -a|--all)
            BACKUP_WEB=1
            BACKUP_MARIADB=1
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
        -v|--verbose)
            VERBOSE=1
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

# Hardware & Environment Auto-Detection
detect_environment() {
    HW_VENDOR=$(sysctl -n hw.vendor 2>/dev/null || true)
    HW_PRODUCT=$(sysctl -n hw.product 2>/dev/null || true)
    HW_VERSION=$(sysctl -n hw.version 2>/dev/null || true)
    HW_DISKNAMES=$(sysctl -n hw.disknames 2>/dev/null || true)
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

    # 2. Laptop / Mobile Notebook Detection
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

    # 3. Desktop Workstation Detection (X11 / GUI environment active)
    IS_DESKTOP=0
    if [ -n "$DISPLAY" ] || pgrep -x xenodm >/dev/null 2>&1 || pgrep -x Xorg >/dev/null 2>&1 || pgrep -x wayland >/dev/null 2>&1; then
        IS_DESKTOP=1
    fi

    # Auto-detection hierarchy:
    # 1. Laptop (battery present takes precedence)
    # 2. Desktop (GUI active, non-laptop)
    # 3. Cloud VPS (hypervisor active, headless)
    # 4. Bare-metal Server (physical, headless)
    if [ "$IS_LAPTOP" -eq 1 ]; then
        DETECTED_ENV="laptop"
        DETECTED_DETAIL="Laptop / Mobile Notebook (${LAPTOP_DETAIL})"
    elif [ "$IS_DESKTOP" -eq 1 ]; then
        DETECTED_ENV="desktop"
        DETECTED_DETAIL="Desktop Workstation (Active Display)"
    elif [ "$IS_VM" -eq 1 ]; then
        DETECTED_ENV="vps"
        DETECTED_DETAIL="Cloud VPS / Virtual Machine (${VM_TYPE})"
    else
        DETECTED_ENV="server"
        SERVER_DESC="${HW_VENDOR} ${HW_PRODUCT}"
        [ -z "$(echo "$SERVER_DESC" | tr -d ' ')" ] && SERVER_DESC="Generic Physical Hardware"
        DETECTED_DETAIL="Bare-metal Physical Server (${SERVER_DESC})"
    fi
}

# Normalize profile alias
case "$PROFILE" in
    baremetal|bare-metal)
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
    echo "Notice: Auto-detected environment: ${DETECTED_DETAIL} -> Profile: ${PROFILE}"
else
    detect_environment
fi

case "$PROFILE" in
    desktop|laptop|server|vps|config) ;;
    *)
        echo "Error: Invalid profile '${PROFILE}'. Choose from: server (or baremetal), desktop, laptop, vps, config." >&2
        exit 1
        ;;
esac

# Auto-skip secrets on 'config' profile unless explicitly disabled
if [ "$PROFILE" = "config" ] && [ "$SKIP_SECRETS" -eq 0 ]; then
    SKIP_SECRETS=1
    echo "Notice: Config profile active: System secrets and password hashes excluded by default."
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
        echo "Notice: Staging in /var/tmp ($((VARTMP_FREE_KB / 1024))MB free vs $((TMP_FREE_KB / 1024))MB in /tmp)."
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
                echo "Warning: Low disk space on ${target_path} (${avail_mb}MB free, required >= ${min_mb}MB). Continuing due to --force." >&2
            else
                echo "Error: Insufficient disk space on ${target_path} (${avail_mb}MB free, required >= ${min_mb}MB). Aborting (use --force to override)." >&2
                exit 1
            fi
        fi
    fi
}

# Compression formatting
if [ "$USE_XZ" -eq 1 ]; then
    EXT="tar.xz"
    TAR_COMP_FLAG="J"
    TEST_FLAG="-tJf"

    # In low-memory environments (e.g. VPS with <= 1GB RAM), bound XZ memory
    PHYSMEM_BYTES=$(sysctl -n hw.physmem64 2>/dev/null || sysctl -n hw.physmem 2>/dev/null || echo 0)
    if [ "$PHYSMEM_BYTES" -gt 0 ] && [ "$PHYSMEM_BYTES" -le 1073741824 ]; then
        export XZ_OPT="${XZ_OPT:--T1 -M 256M}"
        echo "Notice: Low memory detected ($((PHYSMEM_BYTES / 1048576))MB). Restricting XZ: ${XZ_OPT}."
    else
        export XZ_OPT="${XZ_OPT:--T0}"
    fi
else
    EXT="tar.gz"
    TAR_COMP_FLAG="z"
    TEST_FLAG="-tzf"
fi

if [ "$VERBOSE" -eq 1 ]; then
    TAR_OPTS="-c${TAR_COMP_FLAG}vf"
else
    TAR_OPTS="-c${TAR_COMP_FLAG}f"
fi

# Resolve destination directory and archive filename
if [ -n "$CUSTOM_OUTPUT" ]; then
    FINAL_ARCHIVE_PATH="$CUSTOM_OUTPUT"
    FINAL_DEST_DIR="${CUSTOM_OUTPUT%/*}"
    [ "$FINAL_DEST_DIR" = "$CUSTOM_OUTPUT" ] && FINAL_DEST_DIR="."
    ARCHIVE_BASENAME="${CUSTOM_OUTPUT##*/}"
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
    echo "Warning: Destination directory '$FINAL_DEST_DIR' is on the root filesystem (/)." >&2
    echo "         OpenBSD root slices are typically small (1-2GB). Ensure sufficient space or use -d on /home or /mnt." >&2
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

# ==============================================================================
# 1. Target Directory Assembly
# ==============================================================================

# Core base targets for all profiles (verified to exist on filesystem)
set -A BASE_TARGETS etc root usr/local/bin usr/local/sbin var/cron/tabs var/backups var/cron/atjobs
set -A TARGETS
for b_tgt in "${BASE_TARGETS[@]}"; do
    [ -d "/${b_tgt}" ] && set -A TARGETS -- "${TARGETS[@]}" "$b_tgt"
done

if [ "$PROFILE" = "config" ]; then
    echo "Mode: Configuration & Dotfile backup (fast disaster recovery)"
    # Collect all dotfiles and user configurations across /home
    for user_dir in /home/*; do
        if [ -d "$user_dir" ] && [ ! -L "$user_dir" ]; then
            u_rel="${user_dir#/}"
            for dotitem in \
                .config .local/bin bin \
                .xsession .xinitrc .Xdefaults .Xresources .xprofile \
                .cwmrc .fvwmrc .dwm .i3 .sway \
                .profile .kshrc .zshrc .bashrc .tmux.conf \
                .ssh .gnupg .password-store \
                .vim .vimrc .emacs.d .neovim .gitconfig \
                .fonts .themes .icons .mail .mutt .neomutt .newsboat; do
                if [ -e "${user_dir}/${dotitem}" ]; then
                    set -A TARGETS -- "${TARGETS[@]}" "${u_rel}/${dotitem}"
                fi
            done
        fi
    done
elif [ "$PROFILE" = "desktop" ]; then
    echo "Mode: Desktop Workstation backup"
    set -A TARGETS -- "${TARGETS[@]}" home
    [ -d "/usr/local/share/fonts" ] && set -A TARGETS -- "${TARGETS[@]}" usr/local/share/fonts
elif [ "$PROFILE" = "laptop" ]; then
    echo "Mode: Laptop / Mobile Notebook backup"
    set -A TARGETS -- "${TARGETS[@]}" home
    [ -d "/usr/local/share/fonts" ] && set -A TARGETS -- "${TARGETS[@]}" usr/local/share/fonts
elif [ "$PROFILE" = "server" ]; then
    echo "Mode: Bare-metal Physical Server backup"
    set -A TARGETS -- "${TARGETS[@]}" home
    # Chroot daemons & server spools common on OpenBSD servers
    [ -d "/var/unbound" ]     && set -A TARGETS -- "${TARGETS[@]}" var/unbound
    [ -d "/var/named" ]       && set -A TARGETS -- "${TARGETS[@]}" var/named
    [ -d "/var/nsd" ]         && set -A TARGETS -- "${TARGETS[@]}" var/nsd
    [ -d "/etc/wireguard" ]   && set -A TARGETS -- "${TARGETS[@]}" etc/wireguard
    [ -d "/var/mail" ]        && set -A TARGETS -- "${TARGETS[@]}" var/mail
    [ -d "/var/spool/smtpd" ] && set -A TARGETS -- "${TARGETS[@]}" var/spool/smtpd
    [ -d "/var/vmail" ]       && set -A TARGETS -- "${TARGETS[@]}" var/vmail
    [ -d "/var/db/dhcpd" ]    && set -A TARGETS -- "${TARGETS[@]}" var/db/dhcpd

    if [ "$BACKUP_WEB" -eq 1 ] && [ -d "/var/www" ]; then
        echo "Including web server files (/var/www)..."
        set -A TARGETS -- "${TARGETS[@]}" var/www
    fi
elif [ "$PROFILE" = "vps" ]; then
    echo "Mode: Cloud VPS / Virtual Server backup"
    set -A TARGETS -- "${TARGETS[@]}" home
    [ -d "/var/unbound" ]   && set -A TARGETS -- "${TARGETS[@]}" var/unbound
    [ -d "/var/nsd" ]       && set -A TARGETS -- "${TARGETS[@]}" var/nsd
    [ -d "/etc/wireguard" ] && set -A TARGETS -- "${TARGETS[@]}" etc/wireguard
    [ -d "/etc/cloud" ]     && set -A TARGETS -- "${TARGETS[@]}" etc/cloud

    if [ "$BACKUP_WEB" -eq 1 ] && [ -d "/var/www" ]; then
        echo "Including web server files (/var/www)..."
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
        fi
    fi
    set -A TAR_EXCLUDES -- "${TAR_EXCLUDES[@]}" -s "${delim}${pat}${delim}${delim}"
}

add_exclude_dir() {
    typeset dir="$1"
    typeset esc
    esc=$(echo "$dir" | sed 's/\./\\./g')
    add_exclude_rule ".*/${esc}\$"
    add_exclude_rule ".*/${esc}/.*"
}

add_exclude_file() {
    typeset f="$1"
    typeset esc
    esc=$(echo "$f" | sed 's/\./\\./g; s/\*/.*/g')
    add_exclude_rule ".*${esc}\$"
}

add_user_exclude() {
    typeset raw="$1"
    typeset esc
    [ -z "$raw" ] && return 0
    raw="${raw#./}"
    raw="${raw#/}"
    if [[ "$raw" == *\*.* ]]; then
        # Wildcard filename like *.iso, *.log, *backup*.tar*
        esc=$(echo "$raw" | sed 's/\./\\./g; s/\*/.*/g')
        add_exclude_rule ".*${esc}"
    elif [[ "$raw" == */\* ]]; then
        typeset base="${raw%/\*}"
        esc=$(echo "$base" | sed 's/\./\\./g')
        add_exclude_rule ".*/${esc}\$"
        add_exclude_rule ".*/${esc}/.*"
    elif [[ "$raw" == */ ]]; then
        typeset base="${raw%/}"
        esc=$(echo "$base" | sed 's/\./\\./g')
        add_exclude_rule ".*/${esc}\$"
        add_exclude_rule ".*/${esc}/.*"
    elif [[ "$raw" == *\.* ]]; then
        # Specific file with extension
        esc=$(echo "$raw" | sed 's/\./\\./g; s/\*/.*/g')
        add_exclude_rule ".*${esc}"
    else
        # Directory or generic name
        esc=$(echo "$raw" | sed 's/\./\\./g; s/\*/.*/g')
        add_exclude_rule ".*/${esc}\$"
        add_exclude_rule ".*/${esc}/.*"
    fi
}

# Security & Secrets Protection (when --skip-secrets is active or on config profile)
if [ "$SKIP_SECRETS" -eq 1 ]; then
    echo "Applying security exclusions (--skip-secrets active)..."
    # System credential hashes and shadow files (preserve /etc/passwd for UID/GID mapping)
    add_exclude_rule "^etc/master\.passwd\$"
    add_exclude_rule ".*/etc/master\.passwd\$"
    add_exclude_rule "^etc/spwd\.db\$"
    add_exclude_rule ".*/etc/spwd\.db\$"
    add_exclude_rule "^etc/shadow\$"
    add_exclude_rule ".*/etc/shadow\$"
    add_exclude_rule "^etc/skey\$"
    add_exclude_rule ".*/etc/skey\$"

    # SSH host private keys (preserve public keys)
    add_exclude_rule "^etc/ssh/ssh_host_.*_key\$"
    add_exclude_rule ".*/etc/ssh/ssh_host_.*_key\$"

    # TLS and VPN private keys
    add_exclude_rule "^etc/ssl/private/.*"
    add_exclude_rule "^etc/ssl/private\$"
    add_exclude_rule ".*/etc/ssl/private/.*"
    add_exclude_rule ".*/etc/ssl/private\$"
    add_exclude_rule "^etc/wireguard/.*\.key\$"
    add_exclude_rule ".*/etc/wireguard/.*\.key\$"
    add_exclude_rule "^etc/ipsec\.secrets\$"
    add_exclude_rule ".*/etc/ipsec\.secrets\$"

    # User private SSH keys and credentials
    add_exclude_rule ".*\.ssh/id_.*"
    add_exclude_rule ".*\.ssh/.*\.pem\$"
    add_exclude_rule ".*\.ssh/.*\.key\$"
    add_exclude_rule ".*\.gnupg/private-keys-v1\.d/.*"
    add_exclude_rule ".*\.gnupg/secring\.gpg\$"
    add_exclude_rule ".*\.password-store/.*"

    # Disable database dumps when skipping secrets
    BACKUP_MARIADB=0
    BACKUP_POSTGRES=0
fi

# Fundamental Loop & Recursion Protection (ALWAYS enforced to prevent corrupting archives)
add_exclude_rule ".*_backup_.*\.tar\..*"
add_exclude_rule ".*_backup_.*\.sha256"
add_exclude_rule ".*_backup_.*\.sig"
add_exclude_rule ".*/\..*\.tmp\..*"
add_exclude_rule ".*\.tmp\.[0-9]*"
add_exclude_rule ".*\.tar\.gz\$"
add_exclude_rule ".*\.tar\.xz\$"
add_exclude_rule ".*\.tgz\$"

# Sockets (OpenBSD ustar cannot archive sockets; dynamic IPC sockets should never be backed up)
add_exclude_rule ".*\.gnupg/S\..*"
add_exclude_rule ".*\.sock\$"
add_exclude_rule ".*\.socket\$"

# If destination path is inside /root, /home, /var, or other targets, explicitly exclude it
if [ -n "$FINAL_DEST_DIR" ]; then
    rel_dest="${FINAL_DEST_DIR#/}"
    if [ -n "$rel_dest" ] && [ "$rel_dest" != "." ]; then
        add_exclude_rule ".*${ARCHIVE_BASENAME}.*"
        add_exclude_rule ".*${ARCHIVE_BASENAME}\.sha256"
        add_exclude_rule ".*\..*${ARCHIVE_BASENAME}\.tmp\..*"
    fi
fi

# Exclude foreign / network filesystem mountpoints (NFS, sshfs, mfs, tmpfs) under target directories
for mnt_entry in $(mount 2>/dev/null | awk '$5 ~ /^(nfs|fuse|fusefs|mfs|tmpfs|smbfs)$/ {print $3}'); do
    rel_mnt="${mnt_entry#/}"
    if [ -n "$rel_mnt" ]; then
        add_exclude_rule ".*${rel_mnt}/.*"
    fi
done

if [ "$NO_EXCLUDES" -eq 0 ]; then
    if [ "$INCLUDE_CACHES" -eq 0 ]; then
        add_exclude_dir ".cache"
        add_exclude_dir ".thumbnails"
        add_exclude_dir ".local/share/Trash"
        add_exclude_rule ".*/\.mozilla/firefox/[^/]*/cache2\$"
        add_exclude_rule ".*/\.mozilla/firefox/[^/]*/cache2/.*"
        add_exclude_rule ".*/\.mozilla/firefox/[^/]*/storage\$"
        add_exclude_rule ".*/\.mozilla/firefox/[^/]*/storage/.*"
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
    echo "Capturing MariaDB database dump (compressed)..."
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
        if mysqldump -u root --all-databases --single-transaction --routines --events 2>/dev/null \
            | gzip -c > "${SYSINFO_DIR}/mariadb_all_databases.sql.gz"; then
            gz_bytes=$(wc -c < "${SYSINFO_DIR}/mariadb_all_databases.sql.gz" 2>/dev/null || echo 0)
            if [ "$gz_bytes" -lt 50 ]; then
                rm -f "${SYSINFO_DIR}/mariadb_all_databases.sql.gz"
                echo "Warning: MariaDB dump produced no data or daemon not running. Continuing..." >&2
            fi
        else
            rm -f "${SYSINFO_DIR}/mariadb_all_databases.sql.gz"
            echo "Warning: MariaDB dump failed or daemon not running. Continuing..." >&2
        fi
        unset MYSQL_PWD DB_PASS
    else
        echo "Warning: mysqldump command not found. Skipping MariaDB dump." >&2
    fi
fi

if [ "$BACKUP_POSTGRES" -eq 1 ]; then
    echo "Capturing PostgreSQL database dump (compressed)..."
    PG_DUMPALL=$(command -v pg_dumpall 2>/dev/null || true)
    [ -z "$PG_DUMPALL" ] && [ -x "/usr/local/bin/pg_dumpall" ] && PG_DUMPALL="/usr/local/bin/pg_dumpall"
    if [ -n "$PG_DUMPALL" ]; then
        if su -l _postgresql -c "${PG_DUMPALL}" 2>/dev/null \
            | gzip -c > "${SYSINFO_DIR}/postgresql_all_databases.sql.gz"; then
            gz_bytes=$(wc -c < "${SYSINFO_DIR}/postgresql_all_databases.sql.gz" 2>/dev/null || echo 0)
            if [ "$gz_bytes" -lt 50 ]; then
                rm -f "${SYSINFO_DIR}/postgresql_all_databases.sql.gz"
                echo "Warning: PostgreSQL dump produced no data. Continuing..." >&2
            fi
        else
            rm -f "${SYSINFO_DIR}/postgresql_all_databases.sql.gz"
            echo "Warning: PostgreSQL dump failed. Continuing..." >&2
        fi
    else
        echo "Warning: pg_dumpall command not found. Skipping PostgreSQL dump." >&2
    fi
fi

# ==============================================================================
# 4. Comprehensive OpenBSD State & Metadata Capture
# ==============================================================================
echo "Capturing OpenBSD system state and bare-metal metadata..."

# Manifest & System Information
cat <<EOF > "${SYSINFO_DIR}/backup_manifest.txt"
OpenBSD Backup Manifest
Generated    : $(date)
Hostname     : ${HOSTNAME}
Profile      : ${PROFILE}
Platform     : ${DETECTED_DETAIL}
OS Kernel    : $(uname -a)
Architecture : $(sysctl -n hw.machine 2>/dev/null || uname -m)
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
Physical RAM   : $(( $(sysctl -n hw.physmem64 2>/dev/null || sysctl -n hw.physmem 2>/dev/null || echo 0) / 1048576 )) MB
Disks (hw)     : $(sysctl -n hw.disknames 2>/dev/null || echo "Unknown")
HWEOF

pkg_info -mz > "${SYSINFO_DIR}/installed_packages.txt" 2>/dev/null || true
pkg_info > "${SYSINFO_DIR}/installed_packages_full.txt" 2>/dev/null || true
rcctl ls on > "${SYSINFO_DIR}/services_enabled_rcctl.txt" 2>/dev/null || true
rcctl ls manual > "${SYSINFO_DIR}/services_manual_rcctl.txt" 2>/dev/null || true
command -v rcctl >/dev/null 2>&1 && rcctl get --all > "${SYSINFO_DIR}/services_all_flags.txt" 2>/dev/null || true
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

# Softraid / encrypted crypto volumes & Hardware RAID controllers
if command -v bioctl >/dev/null 2>&1; then
    bioctl -i > "${SYSINFO_DIR}/bioctl_status.txt" 2>/dev/null || true
    for ctl in mfi0 ami0 ciss0 mfii0 sr0; do
        if bioctl "$ctl" >/dev/null 2>&1; then
            echo "--- bioctl ${ctl} ---" >> "${SYSINFO_DIR}/bioctl_status.txt"
            bioctl "$ctl" >> "${SYSINFO_DIR}/bioctl_status.txt" 2>/dev/null || true
        fi
    done
    [ -s "${SYSINFO_DIR}/bioctl_status.txt" ] || rm -f "${SYSINFO_DIR}/bioctl_status.txt"

    # Softraid recreation helper documentation
    if bioctl sr0 >/dev/null 2>&1; then
        {
            echo "# Softraid Crypto Volume Reconstruction Helper"
            echo "# To recreate this encrypted volume on a replacement bare-metal drive:"
            echo "# 1. Initialize disklabel partition (e.g. type RAID, partition 'a'):"
            echo "#    disklabel -E <target_disk>"
            echo "# 2. Assemble softraid crypto container:"
            sr_chunks=$(bioctl sr0 2>/dev/null | awk '/Chunk/ {print $NF}' | tr '\n' ' ')
            if [ -n "$sr_chunks" ]; then
                echo "#    bioctl -c C -l ${sr_chunks}softraid0"
            else
                echo "#    bioctl -c C -l <chunk_duid>.a softraid0"
            fi
            echo "# 3. Format and mount new pseudo-device (e.g. sdX):"
            echo "#    newfs /dev/rsdXc && mount /dev/sdXc /mnt"
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
ifconfig -A > "${SYSINFO_DIR}/ifconfig.txt" 2>/dev/null || true
netstat -rn > "${SYSINFO_DIR}/routing_table.txt" 2>/dev/null || true
command -v route >/dev/null 2>&1 && route -n show > "${SYSINFO_DIR}/routing_table_detailed.txt" 2>/dev/null || true
command -v netstat >/dev/null 2>&1 && netstat -ni > "${SYSINFO_DIR}/netstat_interfaces.txt" 2>/dev/null || true
command -v arp >/dev/null 2>&1 && arp -an > "${SYSINFO_DIR}/arp_table.txt" 2>/dev/null || true
command -v ndp >/dev/null 2>&1 && ndp -an > "${SYSINFO_DIR}/ndp_table.txt" 2>/dev/null || true

# Firewall and packet filter rules
if command -v pfctl >/dev/null 2>&1; then
    pfctl -sr > "${SYSINFO_DIR}/pf_rules.txt" 2>/dev/null || true
    echo "--- NAT / Redirection Rules ---" >> "${SYSINFO_DIR}/pf_rules.txt"
    pfctl -sn >> "${SYSINFO_DIR}/pf_rules.txt" 2>/dev/null || true
    [ -s "${SYSINFO_DIR}/pf_rules.txt" ] || rm -f "${SYSINFO_DIR}/pf_rules.txt"
fi

# Workstation & Desktop hardware state
if [[ "$PROFILE" == "desktop" || "$PROFILE" == "laptop" ]] || [ -n "$DISPLAY" ]; then
    command -v wsconsctl >/dev/null 2>&1 && wsconsctl -a > "${SYSINFO_DIR}/wsconsctl_state.txt" 2>/dev/null || true
    command -v mixerctl >/dev/null 2>&1 && mixerctl -a > "${SYSINFO_DIR}/mixerctl_state.txt" 2>/dev/null || true
    command -v audioctl >/dev/null 2>&1 && audioctl -a > "${SYSINFO_DIR}/audioctl_state.txt" 2>/dev/null || true

    if [ -n "$FINAL_USER" ] && [ -n "$DISPLAY" ]; then
        su -l "$FINAL_USER" -c "xrandr --verbose" > "${SYSINFO_DIR}/xrandr_modes.txt" 2>/dev/null || true
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
            ifconfig "$wif" 2>/dev/null || true
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
            echo "  - Check mixerctl_state.txt and audioctl_state.txt for sound outputs."
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

echo "To extract the entire archive to root (/), run:"
echo "  tar -xpf <ARCHIVE_PATH> -C /"
echo "============================================================"
RESCUE_EOF
chmod 755 "${SYSINFO_DIR}/quick-restore.sh"

# ==============================================================================
# 5. Archive Creation & Validation
# ==============================================================================
echo "Creating backup archive: ${FINAL_ARCHIVE_PATH}..."

# OpenBSD tar exits with code 1 if it encounters active UNIX domain sockets
# (e.g., dbus, X11, sndio, php-fpm). We catch code 1 and verify archive integrity.
set +e
nice -n 15 tar "${TAR_OPTS}" "${TMP_BACKUP_FILE}" \
    "${TAR_EXCLUDES[@]}" \
    -C / "${TARGETS[@]}" \
    -C "${SYSINFO_STAGE_DIR}" _sysinfo \
    2> "${TAR_ERR_FILE}"
TAR_EXIT=$?
set -e

if [ "$TAR_EXIT" -ne 0 ]; then
    echo "Validating archive integrity after tar warnings..."
    if ! tar ${TEST_FLAG} "${TMP_BACKUP_FILE}" >/dev/null 2>&1; then
        cat "${TAR_ERR_FILE}" >&2
        echo "Error: Archive creation failed (exit code $TAR_EXIT)." >&2
        exit 1
    fi
    echo "Archive integrity verified. Non-fatal warnings encountered:"
    sed 's/^tar: /  - /' "${TAR_ERR_FILE}"
    echo ""
fi

# Move archive into final destination atomically
mv "${TMP_BACKUP_FILE}" "${FINAL_ARCHIVE_PATH}"

# Generate SHA256 Checksum file alongside archive
echo "Generating SHA256 checksum..."
if command -v sha256 >/dev/null 2>&1; then
    ( cd "${FINAL_DEST_DIR}" && sha256 "${FINAL_ARCHIVE_PATH##*/}" > "${FINAL_ARCHIVE_PATH##*/}.sha256" )
elif command -v sha256sum >/dev/null 2>&1; then
    ( cd "${FINAL_DEST_DIR}" && sha256sum "${FINAL_ARCHIVE_PATH##*/}" > "${FINAL_ARCHIVE_PATH##*/}.sha256" )
elif command -v shasum >/dev/null 2>&1; then
    ( cd "${FINAL_DEST_DIR}" && shasum -a 256 "${FINAL_ARCHIVE_PATH##*/}" > "${FINAL_ARCHIVE_PATH##*/}.sha256" )
fi

# Cryptographic signing via OpenBSD signify(1)
if [ -z "$SIGN_KEY" ] && [ -f "/etc/signify/backup.sec" ]; then
    SIGN_KEY="/etc/signify/backup.sec"
fi

if [ -n "$SIGN_KEY" ]; then
    if command -v signify >/dev/null 2>&1; then
        echo "Signing archive with OpenBSD signify (${SIGN_KEY})..."
        if ( cd "${FINAL_DEST_DIR}" && signify -S -s "$SIGN_KEY" -m "${FINAL_ARCHIVE_PATH##*/}" -x "${FINAL_ARCHIVE_PATH##*/}.sig" ); then
            echo "Archive signed successfully: ${FINAL_ARCHIVE_PATH}.sig"
        else
            echo "Error: signify signing failed!" >&2
            exit 1
        fi
    else
        echo "Warning: signify command not found. Skipping archive signing." >&2
    fi
fi

# Assign ownership to calling non-root user if run via doas/sudo
if [ -n "$DOAS_USER" ] || [ -n "$SUDO_USER" ]; then
    if [ "$SKIP_SECRETS" -eq 1 ] || [ "$FORCE_CHOWN" -eq 1 ]; then
        chown "${FINAL_USER}" "${FINAL_ARCHIVE_PATH}" "${FINAL_ARCHIVE_PATH}.sha256" 2>/dev/null || true
        [ -f "${FINAL_ARCHIVE_PATH}.sig" ] && chown "${FINAL_USER}" "${FINAL_ARCHIVE_PATH}.sig" 2>/dev/null || true
    else
        echo "Notice: Archive contains system credentials and private keys."
        echo "        Ownership retained as root:wheel (0600) for security. Use --chown to override."
    fi
fi

# ==============================================================================
# 6. Retention & Pruning
# ==============================================================================
if [ "$KEEP_COUNT" -gt 0 ]; then
    echo "Applying retention policy (keeping last ${KEEP_COUNT} backups)..."
    ARCHIVE_PREFIX="${HOSTNAME}_${PROFILE}_backup_"
    
    # List actual archives only (.tar.gz, .tar.xz, .tgz) in chronological order (oldest first)
    set -A EXISTING_BACKUPS
    while IFS= read -r f || [ -n "$f" ]; do
        case "$f" in
            *.tar.gz|*.tar.xz|*.tgz)
                [ -f "$f" ] && set -A EXISTING_BACKUPS -- "${EXISTING_BACKUPS[@]}" "$f"
                ;;
        esac
    done <<EOF
$(ls -1tr "${FINAL_DEST_DIR}/${ARCHIVE_PREFIX}"*.tar.gz "${FINAL_DEST_DIR}/${ARCHIVE_PREFIX}"*.tar.xz "${FINAL_DEST_DIR}/${ARCHIVE_PREFIX}"*.tgz 2>/dev/null || true)
EOF

    TOTAL_COUNT=${#EXISTING_BACKUPS[@]}

    if [ "$TOTAL_COUNT" -gt "$KEEP_COUNT" ]; then
        EXCESS=$((TOTAL_COUNT - KEEP_COUNT))
        i=0
        while [ "$i" -lt "$EXCESS" ]; do
            OLD_FILE="${EXISTING_BACKUPS[$i]}"
            if [ -f "$OLD_FILE" ]; then
                echo "Pruning old archive: ${OLD_FILE##*/}"
                rm -f "$OLD_FILE" "${OLD_FILE}.sha256" "${OLD_FILE}.sig" 2>/dev/null || true
            fi
            i=$((i + 1))
        done
    fi
fi

# ==============================================================================
# 7. Remote Upload via SCP
# ==============================================================================
if [ -n "$UPLOAD_DEST" ]; then
    echo "Uploading archive and checksum to ${UPLOAD_DEST}..."
    UPLOAD_SUCCESS=0
    ESC_ARCHIVE=$(shell_escape "$FINAL_ARCHIVE_PATH")
    ESC_SHA=$(shell_escape "${FINAL_ARCHIVE_PATH}.sha256")
    ESC_DEST=$(shell_escape "$UPLOAD_DEST")
    EXTRA_SIG=""
    if [ -f "${FINAL_ARCHIVE_PATH}.sig" ]; then
        ESC_SIG=$(shell_escape "${FINAL_ARCHIVE_PATH}.sig")
        EXTRA_SIG="'${ESC_SIG}'"
    fi

    # Use invoking user's SSH keys and agent when run under doas
    if [ -n "$DOAS_USER" ]; then
        if su -l "$DOAS_USER" -c "scp -q '${ESC_ARCHIVE}' '${ESC_SHA}' ${EXTRA_SIG} '${ESC_DEST}'"; then
            UPLOAD_SUCCESS=1
        fi
    elif [ -n "$SUDO_USER" ]; then
        if su -l "$SUDO_USER" -c "scp -q '${ESC_ARCHIVE}' '${ESC_SHA}' ${EXTRA_SIG} '${ESC_DEST}'"; then
            UPLOAD_SUCCESS=1
        fi
    else
        if scp -q "${FINAL_ARCHIVE_PATH}" "${FINAL_ARCHIVE_PATH}.sha256" ${EXTRA_SIG:+"${FINAL_ARCHIVE_PATH}.sig"} "${UPLOAD_DEST}"; then
            UPLOAD_SUCCESS=1
        fi
    fi

    if [ "$UPLOAD_SUCCESS" -eq 1 ]; then
        echo "Remote upload completed successfully!"
    else
        echo "Warning: Remote upload failed. Check SSH keys and network." >&2
    fi
fi

# ==============================================================================
# 8. Desktop Notification
# ==============================================================================
ARCHIVE_SIZE=$(ls -lh "${FINAL_ARCHIVE_PATH}" | awk '{print $5}')
if [ "$SEND_NOTIFY" -eq 1 ] && [ -n "$FINAL_USER" ]; then
    NOTIFY_TITLE="OpenBSD Backup Complete"
    NOTIFY_MSG="Archive: ${FINAL_ARCHIVE_PATH##*/}\nSize: ${ARCHIVE_SIZE}\nProfile: ${PROFILE}"
    ESC_TITLE=$(shell_escape "$NOTIFY_TITLE")
    ESC_MSG=$(shell_escape "$NOTIFY_MSG")
    ESC_BASE=$(shell_escape "${FINAL_ARCHIVE_PATH##*/}")
    if command -v notify-send >/dev/null 2>&1; then
        su -l "$FINAL_USER" -c "notify-send -i drive-harddisk '${ESC_TITLE}' '${ESC_MSG}'" 2>/dev/null || true
    elif command -v xmessage >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
        su -l "$FINAL_USER" -c "xmessage -center -buttons OK:0 '${ESC_TITLE}: ${ESC_BASE} (${ARCHIVE_SIZE})'" 2>/dev/null || true
    fi
fi

# ==============================================================================
# 9. Summary Report
# ==============================================================================
echo ""
echo "============================================================"
echo " OpenBSD Backup Summary"
echo "============================================================"
echo "Archive File : ${FINAL_ARCHIVE_PATH}"
echo "SHA256 File  : ${FINAL_ARCHIVE_PATH}.sha256"
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
echo "Backup completed successfully!"
