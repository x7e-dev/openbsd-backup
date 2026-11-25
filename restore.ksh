#!/bin/ksh
# ==============================================================================
# restore.ksh
#
# Rapid, robust disaster recovery and restoration tool for OpenBSD.
# Paired with backup.ksh to inspect, verify, diff, decrypt, and restore system
# configurations, user dotfiles, packages, services, and bare-metal states.
# Read-only modes (--show-info, --verify, --list) also run cleanly on macOS.
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

# Enforce strict permissions for all extraction and workspace operations (0700 dirs, 0600 files)
umask 077

PROGNAME="${0##*/}"
OS_NAME=$(uname -s)

usage() {
    cat <<EOF
Usage: ${PROGNAME} <MODE> [OPTIONS] <ARCHIVE> [PATH]

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

Examples:
  # Inspect what's inside a backup archive (gzip, xz, zstd, or age-encrypted):
  ./restore.ksh --show-info mybackup.tar.zst
  ./restore.ksh --show-info -K ~/backup.age.key mybackup.tar.zst.age

  # Verify SHA256 checksum, signify signature, and archive readability:
  ./restore.ksh --verify -S /etc/signify/backup.pub mybackup.tar.gz

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
DECRYPT_KEY="${AGE_KEY_FILE:-}"
OVERWRITE_FSTAB=0
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
        -K|--decrypt-key)
            if [[ -n "$2" && "$2" != -* ]] && [ -f "$2" ]; then
                DECRYPT_KEY="$2"
                shift 2
            else
                echo "Error: --decrypt-key requires a valid age identity key file path." >&2
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
        --overwrite-fstab)
            OVERWRITE_FSTAB=1
            shift
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

# Detect encryption (.age) and compression format (portable across OpenBSD & macOS)
IS_ENCRYPTED=0
ARCHIVE_INNER="$ARCHIVE"
case "$ARCHIVE" in
    *.age)
        IS_ENCRYPTED=1
        ARCHIVE_INNER="${ARCHIVE%.age}"
        ;;
esac

DECOMPRESSOR=""
case "$ARCHIVE_INNER" in
    *.tar.xz)
        DECOMPRESSOR="xz"
        ;;
    *.tar.zst)
        DECOMPRESSOR="zstd"
        ;;
    *.tar.gz|*.tgz)
        DECOMPRESSOR="gzip"
        ;;
    *)
        echo "Error: Unsupported archive format for '${ARCHIVE}'. Expected .tar.gz, .tgz, .tar.xz, .tar.zst (or .age encrypted)." >&2
        exit 1
        ;;
esac

TAR_EXTRACT_STREAM_FLAGS="-xpf"
[ "$VERBOSE" -eq 1 ] && TAR_EXTRACT_STREAM_FLAGS="-xvpf"

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

require_stream_tools() {
    if [ "$IS_ENCRYPTED" -eq 1 ]; then
        if ! command -v age >/dev/null 2>&1; then
            echo "Error: Archive is age-encrypted but 'age' is not installed (OpenBSD: pkg_add age, macOS: brew install age)." >&2
            exit 1
        fi
        if [ -z "$DECRYPT_KEY" ]; then
            echo "Error: Archive '${ARCHIVE}' is age-encrypted. Provide an identity file via -K/--decrypt-key or AGE_KEY_FILE." >&2
            exit 1
        fi
    fi
    case "$DECOMPRESSOR" in
        xz)
            if ! command -v xz >/dev/null 2>&1; then
                echo "Error: 'xz' is required to read .tar.xz archives (OpenBSD: pkg_add xz, macOS: brew install xz)." >&2
                exit 1
            fi
            ;;
        zstd)
            if ! command -v zstd >/dev/null 2>&1; then
                echo "Error: 'zstd' is required to read .tar.zst archives (OpenBSD: pkg_add zstd, macOS: brew install zstd)." >&2
                exit 1
            fi
            ;;
    esac
}

# Temporary directory handling
TMP_WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/restore_work.XXXXXXXXXX")
cleanup() {
    rm -rf "${TMP_WORKDIR}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM QUIT

# Stream decrypted + decompressed tar bytes to stdout
stream_tar_bytes() {
    if [ "$IS_ENCRYPTED" -eq 1 ]; then
        case "$DECOMPRESSOR" in
            gzip) age -d -i "${DECRYPT_KEY}" "${ARCHIVE}" | gzip -dc ;;
            xz)   age -d -i "${DECRYPT_KEY}" "${ARCHIVE}" | xz -dc ;;
            zstd) age -d -i "${DECRYPT_KEY}" "${ARCHIVE}" | zstd -dc ;;
        esac
    else
        case "$DECOMPRESSOR" in
            gzip) gzip -dc "${ARCHIVE}" ;;
            xz)   xz -dc "${ARCHIVE}" ;;
            zstd) zstd -dc "${ARCHIVE}" ;;
        esac
    fi
}

# Run tar reading from stream_tar_bytes, tolerating SIGPIPE (141) on upstream decompressor
# when tar stops early on targeted extractions, while strictly checking tar's exit code.
run_tar_stream() {
    typeset rc_file="${TMP_WORKDIR}/.tar_rc"
    typeset src_file="${TMP_WORKDIR}/.src_rc"
    rm -f "$rc_file" "$src_file"
    set +e
    ( stream_tar_bytes; echo $? > "$src_file" ) | ( tar "$@"; echo $? > "$rc_file" )
    set -e
    typeset tar_rc=$(cat "$rc_file" 2>/dev/null || echo 1)
    typeset src_rc=$(cat "$src_file" 2>/dev/null || echo 1)
    if [ "$tar_rc" -ne 0 ]; then
        return "$tar_rc"
    fi
    if [ "$src_rc" -ne 0 ] && [ "$src_rc" -ne 141 ]; then
        return "$src_rc"
    fi
    return 0
}

# Cache archive file listing once per run to avoid redundant decompression passes
ARCHIVE_LIST_CACHE=""
get_archive_listing() {
    if [ -z "$ARCHIVE_LIST_CACHE" ] || [ ! -f "$ARCHIVE_LIST_CACHE" ]; then
        require_stream_tools
        ARCHIVE_LIST_CACHE="${TMP_WORKDIR}/archive_listing.txt"
        run_tar_stream -tf - > "$ARCHIVE_LIST_CACHE"
    fi
    echo "$ARCHIVE_LIST_CACHE"
}

# Warn if backup OpenBSD release differs from live system when restoring to /
check_os_release_mismatch() {
    if [ "$RESTORE_DEST" != "/" ] || [ "$OS_NAME" != "OpenBSD" ]; then
        return 0
    fi
    typeset manifest_dir="${TMP_WORKDIR}/release_check"
    mkdir -p "$manifest_dir"
    run_tar_stream -xf - -C "$manifest_dir" _sysinfo/backup_manifest.txt 2>/dev/null || true
    if [ -f "${manifest_dir}/_sysinfo/backup_manifest.txt" ]; then
        typeset bak_rel=$(awk -F: '/^OS Release/{gsub(/^[ \t]+/,"",$2); print $2}' "${manifest_dir}/_sysinfo/backup_manifest.txt" 2>/dev/null || true)
        if [ -z "$bak_rel" ]; then
            bak_rel=$(awk '/^OS Kernel/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/) {print $i; exit}}' "${manifest_dir}/_sysinfo/backup_manifest.txt" 2>/dev/null || true)
        fi
        typeset live_rel=$(uname -r)
        if [ -n "$bak_rel" ] && [ "$bak_rel" != "$live_rel" ]; then
            echo "" >&2
            echo "============================================================" >&2
            echo " WARNING: OpenBSD release mismatch detected!" >&2
            echo "   Backup OS Release : ${bak_rel}" >&2
            echo "   Live OS Release   : ${live_rel}" >&2
            echo " Restoring /etc directly onto a different OpenBSD release may" >&2
            echo " downgrade base scripts (/etc/rc, /etc/netstart, /etc/rc.d/*)." >&2
            echo " Consider restoring to a staging dir (--dest /mnt/staging) and" >&2
            echo " merging configs selectively, or running sysmerge(8) afterward." >&2
            echo "============================================================" >&2
        fi
    fi
}

# ==============================================================================
# Mode Implementations
# ==============================================================================

# 1. VERIFY
verify_archive() {
    echo "Verifying archive integrity for: ${ARCHIVE}..."

    ARCHIVE_DIR="${ARCHIVE%/*}"
    [ "$ARCHIVE_DIR" = "$ARCHIVE" ] && ARCHIVE_DIR="."
    ARCHIVE_BASE="${ARCHIVE##*/}"

    # Check for OpenBSD signify signature (.sha256.sig preferred, legacy .sig supported)
    SHA_SIG_FILE="${ARCHIVE}.sha256.sig"
    LEGACY_SIG_FILE="${ARCHIVE}.sig"
    SHA_FILE="${ARCHIVE}.sha256"
    SIG_VERIFIED_SHA=0

    if [ -z "$SIG_KEY" ] && [ -f "/etc/signify/backup.pub" ]; then
        SIG_KEY="/etc/signify/backup.pub"
    fi

    if [ -n "$SIG_KEY" ] || [ -f "$SHA_SIG_FILE" ] || [ -f "$LEGACY_SIG_FILE" ]; then
        echo "Checking cryptographic signature (signify)..."
        if [ ! -f "$SHA_SIG_FILE" ] && [ ! -f "$LEGACY_SIG_FILE" ]; then
            echo "Error: No archive signature file found ('${SHA_SIG_FILE}' or '${LEGACY_SIG_FILE}')!" >&2
            return 1
        fi
        if [ -z "$SIG_KEY" ]; then
            echo "Error: Signature file exists but no signify public key provided (use -S/--sig-key)." >&2
            return 1
        fi
        if ! command -v signify >/dev/null 2>&1; then
            echo "Error: signify verification required but 'signify' command not found!" >&2
            return 1
        fi

        # Resolve SIG_KEY to absolute path before cd'ing to ARCHIVE_DIR
        case "$SIG_KEY" in
            /*) ABS_SIG_KEY="$SIG_KEY" ;;
            *)  ABS_SIG_KEY="$(pwd)/${SIG_KEY}" ;;
        esac

        if [ -f "$SHA_SIG_FILE" ]; then
            if ( cd "$ARCHIVE_DIR" && signify -C -p "$ABS_SIG_KEY" -x "${ARCHIVE_BASE}.sha256.sig" >/dev/null 2>&1 ); then
                echo "Success: OpenBSD signify signature and embedded SHA256 checksum are valid."
                SIG_VERIFIED_SHA=1
            else
                echo "Error: OpenBSD signify -C verification failed!" >&2
                return 1
            fi
        else
            if signify -V -p "$ABS_SIG_KEY" -m "$ARCHIVE" -x "$LEGACY_SIG_FILE" >/dev/null 2>&1; then
                echo "Success: OpenBSD signify signature is valid (legacy .sig format)."
            else
                echo "Error: OpenBSD signify signature verification failed!" >&2
                return 1
            fi
        fi
    fi

    # Check companion SHA256 checksum file (unless already verified by signify -C)
    if [ "$SIG_VERIFIED_SHA" -eq 0 ]; then
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
    fi

    # Test archive readability (for .age archives, test decryption if -K was supplied)
    if [ "$IS_ENCRYPTED" -eq 1 ] && [ -z "$DECRYPT_KEY" ]; then
        if head -n 1 "$ARCHIVE" 2>/dev/null | grep -q '^age-encryption\.org/'; then
            echo "Success: Valid age-encrypted archive header detected (pass -K/--decrypt-key to test full decryption & tar readability)."
            return 0
        else
            echo "Error: File has .age extension but does not appear to be a valid age-encrypted archive." >&2
            return 1
        fi
    fi

    require_stream_tools
    echo "Testing archive readability..."
    if run_tar_stream -tf - >/dev/null 2>&1; then
        echo "Success: Archive structure is valid and decompressible."
        return 0
    else
        echo "Error: Archive appears corrupted, wrong decryption key, or unreadable." >&2
        return 1
    fi
}

# 2. SHOW INFO
show_info() {
    require_stream_tools
    echo "============================================================"
    echo " Backup Archive Information: ${ARCHIVE##*/}"
    echo "============================================================"

    # Extract _sysinfo files to temporary workspace safely (without -p for non-root safety)
    run_tar_stream -xf - -C "${TMP_WORKDIR}" _sysinfo 2>/dev/null || \
    run_tar_stream -xf - -C "${TMP_WORKDIR}" ./_sysinfo 2>/dev/null || true

    SYSINFO="${TMP_WORKDIR}/_sysinfo"
    [ -d "${TMP_WORKDIR}/./_sysinfo" ] && SYSINFO="${TMP_WORKDIR}/./_sysinfo"

    # Support legacy archives containing openbsd_sysinfo.* metadata folder
    if [ ! -d "$SYSINFO" ]; then
        list_file=$(get_archive_listing)
        legacy_dir=$(grep -E '^(\./)?openbsd_sysinfo\.[^/]+/' "$list_file" | head -n 1 | sed -e 's#^\./##' -e 's#/.*##')
        if [ -n "$legacy_dir" ]; then
            run_tar_stream -xf - -C "${TMP_WORKDIR}" "$legacy_dir" 2>/dev/null || \
            run_tar_stream -xf - -C "${TMP_WORKDIR}" "./$legacy_dir" 2>/dev/null || true
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
            sed 's/^/  /' "${SYSINFO}/hardware_type.txt"
            echo "------------------------------------------------------------"
        fi

        if [ -f "${SYSINFO}/cloud_metadata.txt" ]; then
            echo "Cloud VPS & Virtualization Details:"
            sed 's/^/  /' "${SYSINFO}/cloud_metadata.txt"
            echo "------------------------------------------------------------"
        fi

        if [ -d "${SYSINFO}/rpi_boot" ]; then
            echo "Raspberry Pi / ARM Boot Partition Snapshot:"
            ls -1 "${SYSINFO}/rpi_boot" | sed 's/^/  - /'
            if [ -f "${SYSINFO}/rpi_boot/config.txt" ]; then
                echo "  config.txt preview:"
                head -n 10 "${SYSINFO}/rpi_boot/config.txt" | sed 's/^/    /'
            fi
            echo "------------------------------------------------------------"
        fi

        if [ -f "${SYSINFO}/apm_status.txt" ]; then
            echo "Laptop Power & Battery Status:"
            sed 's/^/  /' "${SYSINFO}/apm_status.txt"
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
            sed 's/^/  /' "${SYSINFO}/boot.conf"
            echo "------------------------------------------------------------"
        fi

        if [ -f "${SYSINFO}/sndioctl_state.txt" ]; then
            echo "Audio Controls (sndioctl):"
            head -n 10 "${SYSINFO}/sndioctl_state.txt" | sed 's/^/  /'
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
            echo "Service Flag Overrides (rcctl get all):"
            grep -E 'flags=' "${SYSINFO}/services_all_flags.txt" | grep -v 'flags=""' | head -n 10 | sed 's/^/  /' || true
            echo "------------------------------------------------------------"
        fi

        if [ -f "${SYSINFO}/softraid_recreate.txt" ]; then
            echo "Softraid Crypto Configuration:"
            sed 's/^/  /' "${SYSINFO}/softraid_recreate.txt"
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
           [ -f "${SYSINFO}/postgresql_all_databases.sql.gz" ] || [ -f "${SYSINFO}/postgresql_all_databases.sql" ] || \
           [ -d "${SYSINFO}/sqlite" ]; then
            echo "Database Dumps Recorded:"
            [ -f "${SYSINFO}/mariadb_all_databases.sql.gz" ] && echo "  - MariaDB (Compressed): $(ls -lh "${SYSINFO}/mariadb_all_databases.sql.gz" | awk '{print $5}')"
            [ -f "${SYSINFO}/mariadb_all_databases.sql" ] && echo "  - MariaDB (Uncompressed): $(ls -lh "${SYSINFO}/mariadb_all_databases.sql" | awk '{print $5}')"
            [ -f "${SYSINFO}/postgresql_all_databases.sql.gz" ] && echo "  - PostgreSQL (Compressed): $(ls -lh "${SYSINFO}/postgresql_all_databases.sql.gz" | awk '{print $5}')"
            [ -f "${SYSINFO}/postgresql_all_databases.sql" ] && echo "  - PostgreSQL (Uncompressed): $(ls -lh "${SYSINFO}/postgresql_all_databases.sql" | awk '{print $5}')"
            if [ -d "${SYSINFO}/sqlite" ]; then
                for sdb in "${SYSINFO}"/sqlite/*; do
                    [ -f "$sdb" ] && echo "  - SQLite Snapshot: ${sdb##*/} ($(ls -lh "$sdb" | awk '{print $5}'))"
                done
            fi
            echo "------------------------------------------------------------"
        fi

        if ls "${SYSINFO}"/notmuch_tags_*.dump.gz >/dev/null 2>&1; then
            echo "Notmuch Mail Tag Dumps Recorded:"
            for nm in "${SYSINFO}"/notmuch_tags_*.dump.gz; do
                [ -f "$nm" ] && echo "  - ${nm##*/} ($(ls -lh "$nm" | awk '{print $5}'))"
            done
            echo "------------------------------------------------------------"
        fi

        if [ -f "${SYSINFO}/duids.txt" ]; then
            echo "Disk and Partition Layout (DUIDs):"
            head -n 12 "${SYSINFO}/duids.txt" | sed 's/^/  /'
            echo "------------------------------------------------------------"
        fi

        if [ -f "${SYSINFO}/firmware_status.txt" ] && [ -s "${SYSINFO}/firmware_status.txt" ]; then
            echo "Firmware Status:"
            sed 's/^/  /' "${SYSINFO}/firmware_status.txt"
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
    require_stream_tools
    target="${TARGET_PATH:-/etc}"
    # Strip trailing slash (except root '/') and leading slash for tar matching
    [ "$target" != "/" ] && target="${target%/}"
    rel_target="${target#/}"
    echo "Comparing archive against live system path: ${target}..."

    mkdir -p "${TMP_WORKDIR}/sandbox"

    # Extract without -p so non-root diffing does not fail on chown/mode errors
    if ! run_tar_stream -xf - -C "${TMP_WORKDIR}/sandbox" "${rel_target}" 2>/dev/null; then
        run_tar_stream -xf - -C "${TMP_WORKDIR}/sandbox" "./${rel_target}" 2>/dev/null || true
    fi

    extracted_target="${TMP_WORKDIR}/sandbox/${rel_target}"

    if [ ! -e "$extracted_target" ]; then
        echo "Error: Target '${target}' not found in archive." >&2
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
    list_file=$(get_archive_listing)
    pattern="$TARGET_PATH"
    if [ -n "$pattern" ]; then
        echo "Listing files in ${ARCHIVE} matching '${pattern}':"
        grep -E "$pattern" "$list_file" || echo "No files matching '${pattern}' found."
    else
        echo "Listing all contents of ${ARCHIVE}:"
        cat "$list_file"
    fi
}

# 5. RESTORE PACKAGES
restore_packages() {
    require_root
    require_stream_tools
    echo "Restoring packages from archive..."

    if ! run_tar_stream -xf - -C "${TMP_WORKDIR}" _sysinfo/installed_packages.txt 2>/dev/null; then
        list_file=$(get_archive_listing)
        legacy_pkg=$(grep -E '^(\./)?openbsd_sysinfo\.[^/]+/installed_packages\.txt$' "$list_file" | head -n 1 | sed 's#^\./##')
        if [ -n "$legacy_pkg" ] && run_tar_stream -xf - -C "${TMP_WORKDIR}" "$legacy_pkg" 2>/dev/null; then
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
    require_stream_tools
    echo "Restoring enabled services from archive..."

    if ! run_tar_stream -xf - -C "${TMP_WORKDIR}" _sysinfo/services_enabled_rcctl.txt 2>/dev/null; then
        list_file=$(get_archive_listing)
        legacy_svc=$(grep -E '^(\./)?openbsd_sysinfo\.[^/]+/services_enabled_rcctl\.txt$' "$list_file" | head -n 1 | sed 's#^\./##')
        if [ -n "$legacy_svc" ] && run_tar_stream -xf - -C "${TMP_WORKDIR}" "$legacy_svc" 2>/dev/null; then
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

# Validate destination directory and preserve /etc safety backup + fstab snapshot
prepare_live_restore() {
    typeset label="$1"

    if [ "$DRY_RUN" -eq 0 ] && [ ! -d "$RESTORE_DEST" ]; then
        echo "Error: Restore destination directory '${RESTORE_DEST}' does not exist." >&2
        return 1
    fi

    # Pre-restoration integrity and signature verification
    if [ "$DRY_RUN" -eq 0 ]; then
        verify_archive || return 1
    fi
    require_stream_tools

    check_os_release_mismatch

    # Confirmation prompt when modifying live system
    if [ "$DRY_RUN" -eq 0 ] && [ "$FORCE" -eq 0 ] && [ -t 0 ]; then
        echo -n "WARNING: This operation will overwrite ${label} in '${RESTORE_DEST}'. Proceed? [y/N]: "
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
        tar -cf - -C / etc 2>/dev/null | gzip -c > "$ETC_BAK" || true
    fi
}

# Save backup's /etc/fstab aside for manual review when protecting live /etc/fstab
save_backup_fstab_reference() {
    if [ "$DRY_RUN" -eq 0 ] && [ "$RESTORE_DEST" = "/" ] && [ "$OVERWRITE_FSTAB" -eq 0 ]; then
        mkdir -p /var/backups "${TMP_WORKDIR}/fstab_ref"
        if run_tar_stream -xf - -C "${TMP_WORKDIR}/fstab_ref" etc/fstab 2>/dev/null && \
           [ -f "${TMP_WORKDIR}/fstab_ref/etc/fstab" ]; then
            cp "${TMP_WORKDIR}/fstab_ref/etc/fstab" /var/backups/fstab.from-backup
            echo "Notice: Preserved live /etc/fstab to protect disk DUIDs (backup copy saved to /var/backups/fstab.from-backup)."
            echo "        Pass --overwrite-fstab to override."
        fi
    fi
}

# Rebuild OpenBSD password databases when /etc/master.passwd was restored to /
rebuild_pwd_db_if_needed() {
    typeset has_master="$1"
    if [ "$DRY_RUN" -eq 0 ] && [ "$RESTORE_DEST" = "/" ] && [ "$has_master" -eq 1 ]; then
        if [ -f /etc/master.passwd ] && command -v pwd_mkdb >/dev/null 2>&1; then
            echo "Rebuilding password databases (pwd_mkdb -p /etc/master.passwd)..."
            pwd_mkdb -p /etc/master.passwd
        fi
    fi
}

# 7. EXTRACT CONFIG ONLY
restore_config() {
    require_root
    prepare_live_restore "configuration files" || return 1

    echo "Restoring configurations and dotfiles to ${RESTORE_DEST}..."

    list_file=$(get_archive_listing)
    HAS_MASTER_PASSWD=0
    grep -qE '^(\./)?etc/master\.passwd$' "$list_file" && HAS_MASTER_PASSWD=1

    # Filter targets corresponding to /etc, /root, scripts, crontabs, and user dotfiles
    # Exclude heavy application caches/data trees under home/*/.local/share or .mozilla
    grep -E '^(\./)?(etc/|root/|home/[^/]+/(\.[^/]+|bin/)|usr/local/bin/|usr/local/sbin/|var/cron/tabs/)' "$list_file" \
        | grep -vE '^(\./)?home/[^/]+/(\.cache/|\.thumbnails/|\.mozilla/|\.cargo/|\.gradle/|\.m2/|\.local/share/(Trash|Steam|flatpak)/)' \
        > "${TMP_WORKDIR}/config_list.txt" || true

    # Protect live /etc/fstab (DUIDs) and prevent /etc/passwd desync on --skip-secrets archives
    if [ "$RESTORE_DEST" = "/" ]; then
        if [ "$OVERWRITE_FSTAB" -eq 0 ]; then
            grep -vE '^(\./)?etc/fstab$' "${TMP_WORKDIR}/config_list.txt" > "${TMP_WORKDIR}/config_list.tmp" || true
            mv "${TMP_WORKDIR}/config_list.tmp" "${TMP_WORKDIR}/config_list.txt"
        fi
        if [ "$HAS_MASTER_PASSWD" -eq 0 ]; then
            grep -vE '^(\./)?etc/passwd$' "${TMP_WORKDIR}/config_list.txt" > "${TMP_WORKDIR}/config_list.tmp" || true
            mv "${TMP_WORKDIR}/config_list.tmp" "${TMP_WORKDIR}/config_list.txt"
            echo "Notice: Archive has no etc/master.passwd (--skip-secrets); skipping /etc/passwd to avoid desyncing live pwd.db."
        fi
    fi

    if [ ! -s "${TMP_WORKDIR}/config_list.txt" ]; then
        echo "Error: No configuration files identified in archive." >&2
        return 1
    fi

    file_count=$(wc -l < "${TMP_WORKDIR}/config_list.txt" | tr -d ' ')
    echo "Found ${file_count} configuration files/directories to restore."

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[Dry-Run] Would extract configuration files to ${RESTORE_DEST} (single pass)"
        head -n 20 "${TMP_WORKDIR}/config_list.txt" | sed 's/^/  [Dry-Run] /'
        [ "$file_count" -gt 20 ] && echo "  ... (and $((file_count - 20)) more)"
        return 0
    fi

    save_backup_fstab_reference

    # Single-pass extraction using OpenBSD tar -I (or macOS/bsdtar -T)
    if [ "$OS_NAME" = "OpenBSD" ]; then
        LIST_FLAG="-I"
    else
        LIST_FLAG="-T"
    fi

    set +e
    run_tar_stream ${TAR_EXTRACT_STREAM_FLAGS} - -C "${RESTORE_DEST}" "${LIST_FLAG}" "${TMP_WORKDIR}/config_list.txt"
    TAR_CFG_EXIT=$?
    set -e
    if [ "$TAR_CFG_EXIT" -ne 0 ]; then
        echo "Notice: Non-fatal tar warnings encountered during extraction (exit code ${TAR_CFG_EXIT})." >&2
    fi

    rebuild_pwd_db_if_needed "$HAS_MASTER_PASSWD"
    echo "Configuration restore completed!"
}

# 8. FULL RESTORE
restore_full() {
    require_root
    prepare_live_restore "all system files" || return 1

    echo "Extracting complete backup archive to ${RESTORE_DEST}..."

    list_file=$(get_archive_listing)
    HAS_MASTER_PASSWD=0
    grep -qE '^(\./)?etc/master\.passwd$' "$list_file" && HAS_MASTER_PASSWD=1

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[Dry-Run] Would extract all files from ${ARCHIVE} to ${RESTORE_DEST}"
        [ "$RESTORE_DEST" = "/" ] && [ "$OVERWRITE_FSTAB" -eq 0 ] && echo "[Dry-Run] Would protect live /etc/fstab (preserving disk DUIDs)"
        return 0
    fi

    save_backup_fstab_reference

    # Anchored metadata exclusions so user files containing '_sysinfo' are never skipped
    set -A RESTORE_EXCLUDES \
        -s ',^_sysinfo$,,' \
        -s ',^_sysinfo/.*,,' \
        -s ',^\./_sysinfo$,,' \
        -s ',^\./_sysinfo/.*,,' \
        -s ',^openbsd_sysinfo\.[^/]*$,,' \
        -s ',^openbsd_sysinfo\.[^/]*/.*,,' \
        -s ',^\./openbsd_sysinfo\.[^/]*$,,' \
        -s ',^\./openbsd_sysinfo\.[^/]*/.*,,'

    if [ "$RESTORE_DEST" = "/" ]; then
        if [ "$OVERWRITE_FSTAB" -eq 0 ]; then
            set -A RESTORE_EXCLUDES -- "${RESTORE_EXCLUDES[@]}" \
                -s ',^etc/fstab$,,' -s ',^\./etc/fstab$,,'
        fi
        if [ "$HAS_MASTER_PASSWD" -eq 0 ]; then
            set -A RESTORE_EXCLUDES -- "${RESTORE_EXCLUDES[@]}" \
                -s ',^etc/passwd$,,' -s ',^\./etc/passwd$,,'
            echo "Notice: Archive has no etc/master.passwd (--skip-secrets); skipping /etc/passwd to avoid desyncing live pwd.db."
        fi
    fi

    set +e
    run_tar_stream ${TAR_EXTRACT_STREAM_FLAGS} - \
        "${RESTORE_EXCLUDES[@]}" \
        -C "${RESTORE_DEST}"
    TAR_RESTORE_EXIT=$?
    set -e
    if [ "$TAR_RESTORE_EXIT" -ne 0 ]; then
        echo "Notice: Non-fatal tar warnings encountered during extraction (exit code ${TAR_RESTORE_EXIT})." >&2
    fi

    rebuild_pwd_db_if_needed "$HAS_MASTER_PASSWD"
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
        echo "   1. Review /var/backups/fstab.from-backup vs live /etc/fstab (DUIDs)"
        echo "   2. Review /etc/sysctl.conf, /etc/wsconsctl.conf, and /etc/boot.conf"
        echo "   3. Verify network configuration (/etc/hostname.*) and PF firewall (/etc/pf.conf)"
        echo "   4. Reboot system to initialize newly enabled daemons and firmware"
        echo "============================================================"
        ;;
    *)
        echo "Error: Unrecognized mode '${MODE}'." >&2
        usage >&2
        exit 1
        ;;
esac
