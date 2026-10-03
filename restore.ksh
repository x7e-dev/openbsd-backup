#!/bin/ksh
# ==============================================================================
# restore.ksh
#
# Rapid, robust disaster recovery and restoration tool for OpenBSD.
# Paired with backup.ksh to restore system configurations, user dotfiles,
# packages, services, and bare-metal states in minutes.
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

# Enforce strict permissions for all extraction and workspace operations (0700 dirs, 0600 files)
umask 077

PROGNAME="${0##*/}"

usage() {
    cat <<EOF
Usage: ${PROGNAME} <MODE> [OPTIONS] <ARCHIVE> [PATH]

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
  -S, --sig-key PUBKEY         Verify archive signature using OpenBSD signify(1) public key
  -f, --force                  Bypass interactive confirmation and verification warnings
      --no-backup              Do not create safety backup of /etc before restoring
  -n, --dry-run                Simulate restoration actions without modifying system
  -v, --verbose                Enable verbose extraction output
  -h, --help                   Display this help message and exit

Examples:
  # Inspect what's inside a backup archive:
  ./restore.ksh --show-info mybackup.tar.gz

  # Diff the archive's /etc against the current live /etc before applying:
  ./restore.ksh --diff mybackup.tar.gz /etc

  # Fast restore of dotfiles and /etc only:
  doas ./restore.ksh --config-only mybackup.tar.gz

  # Complete bare-metal restore:
  doas ./restore.ksh --all mybackup.tar.gz
EOF
}

# Allow --help / -h without arguments
if [ $# -eq 0 ]; then
    usage
    exit 0
fi

for arg in "$@"; do
    if [ "$arg" = "-h" ] || [ "$arg" = "--help" ]; then
        usage
        exit 0
    fi
done

MODE=""
ARCHIVE=""
TARGET_PATH=""
RESTORE_DEST="/"
DRY_RUN=0
VERBOSE=0
SIG_KEY=""
FORCE=0
NO_BACKUP=0

# Parse options
while [ $# -gt 0 ]; do
    case "$1" in
        -i|--show-info)
            MODE="info"
            if [[ -n "$2" && "$2" != -* ]]; then
                ARCHIVE="$2"
                shift 2
            else
                shift
            fi
            ;;
        -c|--verify)
            MODE="verify"
            if [[ -n "$2" && "$2" != -* ]]; then
                ARCHIVE="$2"
                shift 2
            else
                shift
            fi
            ;;
        -d|--diff)
            MODE="diff"
            if [[ -n "$2" && "$2" != -* ]]; then
                ARCHIVE="$2"
                shift 2
                if [[ -n "$1" && "$1" != -* ]]; then
                    TARGET_PATH="$1"
                    shift
                fi
            else
                shift
            fi
            ;;
        -l|--list)
            MODE="list"
            if [[ -n "$2" && "$2" != -* ]]; then
                ARCHIVE="$2"
                shift 2
                if [[ -n "$1" && "$1" != -* ]]; then
                    TARGET_PATH="$1"
                    shift
                fi
            else
                shift
            fi
            ;;
        -C|--config-only)
            MODE="config"
            if [[ -n "$2" && "$2" != -* ]]; then
                ARCHIVE="$2"
                shift 2
            else
                shift
            fi
            ;;
        -F|--full)
            MODE="full"
            if [[ -n "$2" && "$2" != -* ]]; then
                ARCHIVE="$2"
                shift 2
            else
                shift
            fi
            ;;
        -p|--install-pkgs)
            MODE="pkgs"
            if [[ -n "$2" && "$2" != -* ]]; then
                ARCHIVE="$2"
                shift 2
            else
                shift
            fi
            ;;
        -s|--enable-services)
            MODE="services"
            if [[ -n "$2" && "$2" != -* ]]; then
                ARCHIVE="$2"
                shift 2
            else
                shift
            fi
            ;;
        -a|--all)
            MODE="all"
            if [[ -n "$2" && "$2" != -* ]]; then
                ARCHIVE="$2"
                shift 2
            else
                shift
            fi
            ;;
        --dest)
            if [[ -n "$2" && "$2" != -* ]]; then
                RESTORE_DEST="$2"
                shift 2
            else
                echo "Error: --dest requires a directory path." >&2
                exit 1
            fi
            ;;
        -S|--sig-key)
            if [[ -n "$2" && "$2" != -* ]] && [ -f "$2" ]; then
                SIG_KEY="$2"
                shift 2
            else
                echo "Error: --sig-key requires a valid public key file path." >&2
                exit 1
            fi
            ;;
        -f|--force)
            FORCE=1
            shift
            ;;
        --no-backup)
            NO_BACKUP=1
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=1
            shift
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        *)
            # Positional fallback
            if [ -z "$ARCHIVE" ]; then
                ARCHIVE="$1"
                shift
            elif [ -z "$TARGET_PATH" ]; then
                TARGET_PATH="$1"
                shift
            else
                echo "Error: Unknown option or extra argument '$1'" >&2
                usage >&2
                exit 1
            fi
            ;;
    esac
done

if [ -z "$MODE" ]; then
    echo "Error: No mode specified. Use -h or --help to see available modes." >&2
    exit 1
fi

if [ -z "$ARCHIVE" ]; then
    echo "Error: Backup archive filepath is required." >&2
    exit 1
fi

if [ ! -f "$ARCHIVE" ]; then
    echo "Error: Archive file '${ARCHIVE}' not found." >&2
    exit 1
fi

# Detect compression format
case "$ARCHIVE" in
    *.tar.xz)
        TAR_EXTRACT_FLAG="-Jxpf"
        TAR_TEST_FLAG="-tJf"
        TAR_LIST_FLAG="-tJf"
        ;;
    *.tar.gz|*.tgz)
        TAR_EXTRACT_FLAG="-zxpf"
        TAR_TEST_FLAG="-tzf"
        TAR_LIST_FLAG="-tzf"
        ;;
    *)
        echo "Error: Unsupported archive format for '${ARCHIVE}'. Expected .tar.gz, .tgz, or .tar.xz." >&2
        exit 1
        ;;
esac

[ "$VERBOSE" -eq 1 ] && TAR_EXTRACT_FLAG="-v${TAR_EXTRACT_FLAG#-}"

# Operations that modify the live system require root
require_root() {
    if [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: This operation modifies system files and must be run as root (e.g. via doas)." >&2
        exit 1
    fi
}

# Temporary directory handling
TMP_WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/restore_work.XXXXXXXXXX")
cleanup() {
    rm -rf "${TMP_WORKDIR}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM QUIT

# ==============================================================================
# Mode Implementations
# ==============================================================================

# 1. VERIFY
verify_archive() {
    echo "Verifying archive integrity for: ${ARCHIVE}..."
    
    # Check for SHA256 checksum file
    SHA_FILE="${ARCHIVE}.sha256"
    if [ -f "$SHA_FILE" ]; then
        echo "Checking SHA256 checksum against ${SHA_FILE}..."
        
        EXPECTED_HASH=$(awk '{for(i=1;i<=NF;i++) if(length($i)==64 && $i ~ /^[0-9a-fA-F]+$/) {print tolower($i); exit}}' "$SHA_FILE")
        
        CALC_CMD=""
        if command -v sha256 >/dev/null 2>&1; then
            CALC_CMD="sha256"
        elif command -v sha256sum >/dev/null 2>&1; then
            CALC_CMD="sha256sum"
        elif command -v shasum >/dev/null 2>&1; then
            CALC_CMD="shasum -a 256"
        fi

        if [ -n "$CALC_CMD" ] && [ -n "$EXPECTED_HASH" ]; then
            ACTUAL_HASH=$($CALC_CMD "$ARCHIVE" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if(length($i)==64 && $i ~ /^[0-9a-fA-F]+$/) {print tolower($i); exit}}')
            if [ "$EXPECTED_HASH" = "$ACTUAL_HASH" ]; then
                echo "Success: SHA256 checksum matches (${ACTUAL_HASH})."
            else
                echo "Error: SHA256 checksum mismatch!" >&2
                echo "  Expected: ${EXPECTED_HASH}" >&2
                echo "  Actual  : ${ACTUAL_HASH}" >&2
                return 1
            fi
        else
            echo "Notice: Could not parse or calculate SHA256 hash. Skipping hash check."
        fi
    else
        echo "Notice: No companion .sha256 file found. Skipping checksum comparison."
    fi

    # Check for OpenBSD signify signature (.sig file or --sig-key)
    SIG_FILE="${ARCHIVE}.sig"
    if [ -z "$SIG_KEY" ] && [ -f "/etc/signify/backup.pub" ]; then
        SIG_KEY="/etc/signify/backup.pub"
    fi

    if [ -n "$SIG_KEY" ] || [ -f "$SIG_FILE" ]; then
        echo "Checking cryptographic signature (signify)..."
        if [ ! -f "$SIG_FILE" ]; then
            echo "Error: Archive signature file '${SIG_FILE}' not found!" >&2
            return 1
        fi
        if [ -z "$SIG_KEY" ]; then
            echo "Error: Signature file exists but no signify public key provided (use -S/--sig-key)." >&2
            return 1
        fi
        if command -v signify >/dev/null 2>&1; then
            if signify -V -p "$SIG_KEY" -m "$ARCHIVE" -x "$SIG_FILE" >/dev/null 2>&1; then
                echo "Success: OpenBSD signify signature is valid."
            else
                echo "Error: OpenBSD signify signature verification failed!" >&2
                return 1
            fi
        else
            echo "Warning: signify command not found. Cannot verify signature." >&2
        fi
    fi

    # Test tar archive readability
    echo "Testing archive readability..."
    if tar ${TAR_TEST_FLAG} "${ARCHIVE}" >/dev/null 2>&1; then
        echo "Success: Archive structure is valid and decompressible."
        return 0
    else
        echo "Error: Archive appears corrupted or unreadable." >&2
        return 1
    fi
}

# 2. SHOW INFO
show_info() {
    echo "============================================================"
    echo " Backup Archive Information: ${ARCHIVE##*/}"
    echo "============================================================"
    
    # Extract _sysinfo files to temporary workspace safely
    tar ${TAR_EXTRACT_FLAG} "${ARCHIVE}" -C "${TMP_WORKDIR}" _sysinfo 2>/dev/null || \
    tar ${TAR_EXTRACT_FLAG} "${ARCHIVE}" -C "${TMP_WORKDIR}" ./_sysinfo 2>/dev/null || true
    
    SYSINFO="${TMP_WORKDIR}/_sysinfo"
    [ -d "${TMP_WORKDIR}/./_sysinfo" ] && SYSINFO="${TMP_WORKDIR}/./_sysinfo"

    # Support legacy archives containing openbsd_sysinfo.* metadata folder
    if [ ! -d "$SYSINFO" ]; then
        legacy_dir=$(tar ${TAR_LIST_FLAG} "${ARCHIVE}" 2>/dev/null | grep -E '^(\./)?openbsd_sysinfo\.[^/]+/' | head -n 1 | sed -e 's#^\./##' -e 's#/.*##')
        if [ -n "$legacy_dir" ]; then
            tar ${TAR_EXTRACT_FLAG} "${ARCHIVE}" -C "${TMP_WORKDIR}" "$legacy_dir" 2>/dev/null || \
            tar ${TAR_EXTRACT_FLAG} "${ARCHIVE}" -C "${TMP_WORKDIR}" "./$legacy_dir" 2>/dev/null || true
            [ -d "${TMP_WORKDIR}/${legacy_dir}" ] && SYSINFO="${TMP_WORKDIR}/${legacy_dir}"
        fi
    fi

    if [ -d "$SYSINFO" ]; then
        if [ -f "${SYSINFO}/backup_manifest.txt" ]; then
            cat "${SYSINFO}/backup_manifest.txt"
            echo "------------------------------------------------------------"
        fi

        if [ -f "${SYSINFO}/hardware_type.txt" ]; then
            echo "Hardware & Environment Classification:"
            cat "${SYSINFO}/hardware_type.txt" | sed 's/^/  /'
            echo "------------------------------------------------------------"
        fi

        if [ -f "${SYSINFO}/cloud_metadata.txt" ]; then
            echo "Cloud VPS & Virtualization Details:"
            cat "${SYSINFO}/cloud_metadata.txt" | sed 's/^/  /'
            echo "------------------------------------------------------------"
        fi

        if [ -f "${SYSINFO}/apm_status.txt" ]; then
            echo "Laptop Power & Battery Status:"
            cat "${SYSINFO}/apm_status.txt" | sed 's/^/  /'
            echo "------------------------------------------------------------"
        fi

        if [ -f "${SYSINFO}/bioctl_status.txt" ]; then
            echo "Storage RAID & Crypto Volumes (bioctl):"
            head -n 12 "${SYSINFO}/bioctl_status.txt" | sed 's/^/  /'
            echo "------------------------------------------------------------"
        fi

        if [ -f "${SYSINFO}/wireless_interfaces.txt" ]; then
            echo "Wireless Interfaces Recorded:"
            head -n 10 "${SYSINFO}/wireless_interfaces.txt" | sed 's/^/  /'
            echo "------------------------------------------------------------"
        fi

        if [ -f "${SYSINFO}/boot.conf" ]; then
            echo "Bootloader & Console Configuration (/etc/boot.conf):"
            cat "${SYSINFO}/boot.conf" | sed 's/^/  /'
            echo "------------------------------------------------------------"
        fi

        if [ -f "${SYSINFO}/installed_packages.txt" ]; then
            pkg_cnt=$(wc -l < "${SYSINFO}/installed_packages.txt" | tr -d ' ')
            echo "Installed Packages Recorded: ${pkg_cnt}"
            echo "Top packages:"
            head -n 5 "${SYSINFO}/installed_packages.txt" | sed 's/^/  - /'
            [ "$pkg_cnt" -gt 5 ] && echo "  ... (and $((pkg_cnt - 5)) more)"
            echo "------------------------------------------------------------"
        fi

        if [ -f "${SYSINFO}/services_enabled_rcctl.txt" ]; then
            echo "Active Services Recorded (rcctl ls on):"
            while read -r svc; do
                [ -n "$svc" ] && echo "  - $svc"
            done < "${SYSINFO}/services_enabled_rcctl.txt"
            echo "------------------------------------------------------------"
        fi

        if [ -f "${SYSINFO}/services_all_flags.txt" ]; then
            echo "Service Flag Overrides (rcctl get --all):"
            grep -E 'flags=' "${SYSINFO}/services_all_flags.txt" | grep -v 'flags=""' | head -n 10 | sed 's/^/  /' || true
            echo "------------------------------------------------------------"
        fi

        if [ -f "${SYSINFO}/softraid_recreate.txt" ]; then
            echo "Softraid Crypto Configuration:"
            cat "${SYSINFO}/softraid_recreate.txt" | sed 's/^/  /'
            echo "------------------------------------------------------------"
        fi

        if ls "${SYSINFO}"/disklabel_*.txt >/dev/null 2>&1; then
            echo "Disklabels Available for Bare-Metal Restore (disklabel -R):"
            for dl in "${SYSINFO}"/disklabel_*.txt; do
                [ -f "$dl" ] && echo "  - ${dl##*/}"
            done
            echo "------------------------------------------------------------"
        fi

        if [ -f "${SYSINFO}/mariadb_all_databases.sql.gz" ] || [ -f "${SYSINFO}/mariadb_all_databases.sql" ] || \
           [ -f "${SYSINFO}/postgresql_all_databases.sql.gz" ] || [ -f "${SYSINFO}/postgresql_all_databases.sql" ]; then
            echo "Database Dumps Recorded:"
            [ -f "${SYSINFO}/mariadb_all_databases.sql.gz" ] && echo "  - MariaDB (Compressed): $(ls -lh "${SYSINFO}/mariadb_all_databases.sql.gz" | awk '{print $5}')"
            [ -f "${SYSINFO}/mariadb_all_databases.sql" ] && echo "  - MariaDB (Uncompressed): $(ls -lh "${SYSINFO}/mariadb_all_databases.sql" | awk '{print $5}')"
            [ -f "${SYSINFO}/postgresql_all_databases.sql.gz" ] && echo "  - PostgreSQL (Compressed): $(ls -lh "${SYSINFO}/postgresql_all_databases.sql.gz" | awk '{print $5}')"
            [ -f "${SYSINFO}/postgresql_all_databases.sql" ] && echo "  - PostgreSQL (Uncompressed): $(ls -lh "${SYSINFO}/postgresql_all_databases.sql" | awk '{print $5}')"
            echo "------------------------------------------------------------"
        fi

        if [ -f "${SYSINFO}/duids.txt" ]; then
            echo "Disk and Partition Layout (DUIDs):"
            head -n 12 "${SYSINFO}/duids.txt" | sed 's/^/  /'
            echo "------------------------------------------------------------"
        fi

        if [ -f "${SYSINFO}/firmware_status.txt" ] && [ -s "${SYSINFO}/firmware_status.txt" ]; then
            echo "Firmware Status:"
            cat "${SYSINFO}/firmware_status.txt" | sed 's/^/  /'
            echo "------------------------------------------------------------"
        fi
    else
        echo "Notice: Archive does not contain a _sysinfo metadata folder."
        echo "Archive size: $(ls -lh "${ARCHIVE}" | awk '{print $5}')"
    fi
    echo "============================================================"
}

# 3. DIFF
diff_archive() {
    target="${TARGET_PATH:-/etc}"
    echo "Comparing archive against live system path: ${target}..."
    
    # Strip leading slash for tar extraction matching
    rel_target="${target#/}"
    
    # Extract target from archive into temporary sandbox
    mkdir -p "${TMP_WORKDIR}/sandbox"
    
    if ! tar ${TAR_EXTRACT_FLAG} "${ARCHIVE}" -C "${TMP_WORKDIR}/sandbox" "${rel_target}" 2>/dev/null; then
        echo "Error: Target '${target}' not found in archive." >&2
        return 1
    fi
    
    extracted_target="${TMP_WORKDIR}/sandbox/${rel_target}"
    
    if [ ! -e "$extracted_target" ]; then
        echo "Error: Target '${target}' was not found in archive." >&2
        return 1
    fi

    echo "Running diff -u against live system:"
    echo "============================================================"
    if [ -f "$extracted_target" ]; then
        diff -u "$target" "$extracted_target" || true
    else
        diff -urN "$target" "$extracted_target" || true
    fi
    echo "============================================================"
}

# 4. LIST
list_archive() {
    pattern="$TARGET_PATH"
    if [ -n "$pattern" ]; then
        echo "Listing files in ${ARCHIVE} matching '${pattern}':"
        tar ${TAR_LIST_FLAG} "${ARCHIVE}" | grep -E "$pattern" || echo "No files matching '${pattern}' found."
    else
        echo "Listing all contents of ${ARCHIVE}:"
        tar ${TAR_LIST_FLAG} "${ARCHIVE}"
    fi
}

# 5. RESTORE PACKAGES
restore_packages() {
    require_root
    echo "Restoring packages from archive..."
    
    mkdir -p "${TMP_WORKDIR}/sysinfo"
    if ! tar ${TAR_EXTRACT_FLAG} "${ARCHIVE}" -C "${TMP_WORKDIR}" _sysinfo/installed_packages.txt 2>/dev/null; then
        legacy_pkg=$(tar ${TAR_LIST_FLAG} "${ARCHIVE}" 2>/dev/null | grep -E '^(\./)?openbsd_sysinfo\.[^/]+/installed_packages\.txt$' | head -n 1 | sed 's#^\./##')
        if [ -n "$legacy_pkg" ] && tar ${TAR_EXTRACT_FLAG} "${ARCHIVE}" -C "${TMP_WORKDIR}" "$legacy_pkg" 2>/dev/null; then
            PKG_FILE="${TMP_WORKDIR}/${legacy_pkg}"
        else
            echo "Error: _sysinfo/installed_packages.txt not found in archive." >&2
            return 1
        fi
    else
        PKG_FILE="${TMP_WORKDIR}/_sysinfo/installed_packages.txt"
    fi
    if [ ! -s "$PKG_FILE" ]; then
        echo "Error: No packages listed in installed_packages.txt." >&2
        return 1
    fi

    pkg_count=$(wc -l < "$PKG_FILE" | tr -d ' ')
    echo "Found ${pkg_count} packages to install."

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[Dry-Run] Would run: pkg_add -l ${PKG_FILE}"
        return 0
    fi

    echo "Installing packages via pkg_add -l..."
    if ! pkg_add -l "$PKG_FILE"; then
        echo "Warning: Some packages could not be installed. Continuing with restoration..." >&2
    fi
    echo "Package restoration completed!"
}

# 6. ENABLE SERVICES
enable_services() {
    require_root
    echo "Restoring enabled services from archive..."
    
    if ! tar ${TAR_EXTRACT_FLAG} "${ARCHIVE}" -C "${TMP_WORKDIR}" _sysinfo/services_enabled_rcctl.txt 2>/dev/null; then
        legacy_svc=$(tar ${TAR_LIST_FLAG} "${ARCHIVE}" 2>/dev/null | grep -E '^(\./)?openbsd_sysinfo\.[^/]+/services_enabled_rcctl\.txt$' | head -n 1 | sed 's#^\./##')
        if [ -n "$legacy_svc" ] && tar ${TAR_EXTRACT_FLAG} "${ARCHIVE}" -C "${TMP_WORKDIR}" "$legacy_svc" 2>/dev/null; then
            SVC_FILE="${TMP_WORKDIR}/${legacy_svc}"
        else
            echo "Error: _sysinfo/services_enabled_rcctl.txt not found in archive." >&2
            return 1
        fi
    else
        SVC_FILE="${TMP_WORKDIR}/_sysinfo/services_enabled_rcctl.txt"
    fi
    if [ ! -s "$SVC_FILE" ]; then
        echo "Notice: No services recorded to enable."
        return 0
    fi

    while read -r svc; do
        [ -z "$svc" ] && continue
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "[Dry-Run] Would run: rcctl enable ${svc}"
        else
            echo "Enabling service: ${svc}"
            rcctl enable "$svc" 2>/dev/null || echo "Warning: rcctl enable ${svc} returned error."
        fi
    done < "$SVC_FILE"
    echo "Services restoration completed!"
}

# 7. EXTRACT CONFIG ONLY
restore_config() {
    require_root

    # Pre-restoration integrity and signature verification
    if [ "$DRY_RUN" -eq 0 ]; then
        verify_archive || return 1
    fi

    echo "Restoring configurations and dotfiles to ${RESTORE_DEST}..."

    # Confirmation prompt when modifying live system
    if [ "$DRY_RUN" -eq 0 ] && [ "$FORCE" -eq 0 ] && [ -t 0 ]; then
        echo -n "WARNING: This operation will overwrite configuration files in '${RESTORE_DEST}'. Proceed? [y/N]: "
        read CONFIRM
        case "$CONFIRM" in
            [yY]|[yY][eE][sS]) ;;
            *) echo "Restoration aborted by user." >&2; exit 1 ;;
        esac
    fi

    # Create safety backup of /etc before overwriting live configurations
    if [ "$DRY_RUN" -eq 0 ] && [ "$NO_BACKUP" -eq 0 ] && [ "$RESTORE_DEST" = "/" ] && [ -d "/etc" ]; then
        mkdir -p /var/backups
        ETC_BAK="/var/backups/etc.pre-restore.$(date '+%Y%m%d-%H%M%S').tar.gz"
        echo "Creating pre-restore safety backup of live /etc to ${ETC_BAK}..."
        tar -czf "$ETC_BAK" -C / etc 2>/dev/null || true
    fi
    
    # Filter targets inside the archive that correspond to /etc, /root, and dotfiles
    tar ${TAR_TEST_FLAG} "${ARCHIVE}" > "${TMP_WORKDIR}/full_list.txt"
    grep -E '^(etc/|root/|home/[^/]+/\.[^/]+|usr/local/bin/|usr/local/sbin/|var/cron/tabs/)' \
        "${TMP_WORKDIR}/full_list.txt" > "${TMP_WORKDIR}/config_list.txt" || true

    if [ ! -s "${TMP_WORKDIR}/config_list.txt" ]; then
        echo "Error: No configuration files identified in archive." >&2
        return 1
    fi

    file_count=$(wc -l < "${TMP_WORKDIR}/config_list.txt" | tr -d ' ')
    echo "Found ${file_count} configuration files/directories to restore."

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[Dry-Run] Would extract configuration files to ${RESTORE_DEST}"
        head -n 20 "${TMP_WORKDIR}/config_list.txt" | sed 's/^/  [Dry-Run] /'
        [ "$file_count" -gt 20 ] && echo "  ... (and $((file_count - 20)) more)"
        return 0
    fi

    # Safe batch extraction avoiding xargs quote parsing and command-length overflow
    set -A BATCH
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        set -A BATCH -- "${BATCH[@]}" "$line"
        if [ ${#BATCH[@]} -ge 100 ]; then
            set +e
            tar ${TAR_EXTRACT_FLAG} "${ARCHIVE}" -C "${RESTORE_DEST}" "${BATCH[@]}"
            TAR_BATCH_EXIT=$?
            set -e
            if [ "$TAR_BATCH_EXIT" -ne 0 ]; then
                echo "Notice: Non-fatal tar warnings encountered during batch extraction (exit code ${TAR_BATCH_EXIT})." >&2
            fi
            set -A BATCH
        fi
    done < "${TMP_WORKDIR}/config_list.txt"
    if [ ${#BATCH[@]} -gt 0 ]; then
        set +e
        tar ${TAR_EXTRACT_FLAG} "${ARCHIVE}" -C "${RESTORE_DEST}" "${BATCH[@]}"
        TAR_BATCH_EXIT=$?
        set -e
        if [ "$TAR_BATCH_EXIT" -ne 0 ]; then
            echo "Notice: Non-fatal tar warnings encountered during batch extraction (exit code ${TAR_BATCH_EXIT})." >&2
        fi
    fi
    echo "Configuration restore completed!"
}

# 8. FULL RESTORE
restore_full() {
    require_root

    # Pre-restoration integrity and signature verification
    if [ "$DRY_RUN" -eq 0 ]; then
        verify_archive || return 1
    fi

    echo "Extracting complete backup archive to ${RESTORE_DEST}..."

    # Confirmation prompt when modifying live system
    if [ "$DRY_RUN" -eq 0 ] && [ "$FORCE" -eq 0 ] && [ -t 0 ]; then
        echo -n "WARNING: This operation will overwrite all system files in '${RESTORE_DEST}'. Proceed? [y/N]: "
        read CONFIRM
        case "$CONFIRM" in
            [yY]|[yY][eE][sS]) ;;
            *) echo "Full restoration aborted by user." >&2; exit 1 ;;
        esac
    fi

    # Create safety backup of /etc before full live extraction
    if [ "$DRY_RUN" -eq 0 ] && [ "$NO_BACKUP" -eq 0 ] && [ "$RESTORE_DEST" = "/" ] && [ -d "/etc" ]; then
        mkdir -p /var/backups
        ETC_BAK="/var/backups/etc.pre-restore.$(date '+%Y%m%d-%H%M%S').tar.gz"
        echo "Creating pre-restore safety backup of live /etc to ${ETC_BAK}..."
        tar -czf "$ETC_BAK" -C / etc 2>/dev/null || true
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[Dry-Run] Would extract all files from ${ARCHIVE} to ${RESTORE_DEST}"
        return 0
    fi

    # Exclude _sysinfo and legacy metadata folders from being extracted directly into root
    set +e
    tar ${TAR_EXTRACT_FLAG} "${ARCHIVE}" \
        -s ',.*_sysinfo.*,,' \
        -s ',.*openbsd_sysinfo\..*,,' \
        -C "${RESTORE_DEST}"
    TAR_RESTORE_EXIT=$?
    set -e
    if [ "$TAR_RESTORE_EXIT" -ne 0 ]; then
        echo "Notice: Non-fatal tar warnings encountered during extraction (exit code ${TAR_RESTORE_EXIT})." >&2
    fi
    echo "Full extraction completed!"
}

# ==============================================================================
# Execution Dispatcher
# ==============================================================================
case "$MODE" in
    verify)
        verify_archive
        ;;
    info)
        show_info
        ;;
    diff)
        diff_archive
        ;;
    list)
        list_archive
        ;;
    pkgs)
        restore_packages
        ;;
    services)
        enable_services
        ;;
    config)
        restore_config
        ;;
    full)
        restore_full
        ;;
    all)
        echo "Initiating complete bare-metal restoration..."
        restore_full
        restore_packages
        enable_services
        echo "Updating firmware drivers..."
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "[Dry-Run] Would run: fw_update"
        else
            command -v fw_update >/dev/null 2>&1 && fw_update || true
        fi
        echo ""
        echo "============================================================"
        echo " Bare-Metal Restoration Complete!"
        echo " Recommended Next Steps:"
        echo "   1. Review /etc/sysctl.conf, /etc/wsconsctl.conf, and /etc/boot.conf"
        echo "   2. Verify network configuration (/etc/hostname.*) and PF firewall (/etc/pf.conf)"
        echo "   3. Reboot system to initialize newly enabled daemons and firmware"
        echo "============================================================"
        ;;
    *)
        echo "Error: Unrecognized mode '${MODE}'." >&2
        usage >&2
        exit 1
        ;;
esac
