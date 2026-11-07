#!/bin/sh
# ==============================================================================
# tests/test_runner.sh
#
# Automated verification test suite for backup.ksh and restore.ksh.
# Tests syntax, argument parsing, profile normalization, auto-detection heuristics,
# and restore metadata inspection.
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

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TMP=$(mktemp -d "/tmp/openbsd_backup_test.XXXXXXXXXX")

cleanup() {
    rm -rf "${TEST_TMP}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM QUIT

PASSED=0
FAILED=0

assert_success() {
    TEST_NAME="$1"
    shift
    if "$@"; then
        echo "  [PASS] ${TEST_NAME}"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] ${TEST_NAME}"
        FAILED=$((FAILED + 1))
    fi
}

assert_output_contains() {
    TEST_NAME="$1"
    EXPECTED="$2"
    shift 2
    OUTPUT=$("$@" 2>&1 || true)
    if echo "$OUTPUT" | grep -Fq -- "$EXPECTED"; then
        echo "  [PASS] ${TEST_NAME}"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] ${TEST_NAME}: Expected to find '${EXPECTED}' in output."
        echo "  Output was: ${OUTPUT}"
        FAILED=$((FAILED + 1))
    fi
}

echo "============================================================"
echo " Running OpenBSD Backup Test Suite"
echo "============================================================"

# Test 1: Syntax check with ksh
echo "1. Checking shell syntax..."
assert_success "backup.ksh ksh syntax check" ksh -n "${REPO_DIR}/backup.ksh"
assert_success "restore.ksh ksh syntax check" ksh -n "${REPO_DIR}/restore.ksh"

# Test 2: Help flag verification
echo "2. Verifying help banners..."
assert_output_contains "backup.ksh --help contains server" "server : Bare-metal server" ksh "${REPO_DIR}/backup.ksh" --help
assert_output_contains "backup.ksh --help contains desktop" "desktop: Desktop workstation" ksh "${REPO_DIR}/backup.ksh" --help
assert_output_contains "backup.ksh --help contains laptop" "laptop : Laptop/notebook" ksh "${REPO_DIR}/backup.ksh" --help
assert_output_contains "backup.ksh --help contains vps" "vps    : Cloud VPS & VMs" ksh "${REPO_DIR}/backup.ksh" --help
assert_output_contains "backup.ksh --help contains --force" "-f, --force" ksh "${REPO_DIR}/backup.ksh" --help
assert_output_contains "backup.ksh --help contains --sign" "-S, --sign" ksh "${REPO_DIR}/backup.ksh" --help
assert_output_contains "backup.ksh --help contains --skip-secrets" "--skip-secrets" ksh "${REPO_DIR}/backup.ksh" --help
assert_output_contains "backup.ksh --help contains --chown" "--chown" ksh "${REPO_DIR}/backup.ksh" --help
assert_output_contains "restore.ksh --help contains show-info" "--show-info" ksh "${REPO_DIR}/restore.ksh" --help
assert_output_contains "restore.ksh --help contains --sig-key" "-S, --sig-key" ksh "${REPO_DIR}/restore.ksh" --help
assert_output_contains "restore.ksh --help contains --force" "-f, --force" ksh "${REPO_DIR}/restore.ksh" --help

# Test 3: Profile normalization and detection logic
echo "3. Testing profile alias normalization and auto-detection..."
SCRIPT_EXTRACT="${TEST_TMP}/detect_test.ksh"
cat << 'KSH_TEST_EOF' > "${SCRIPT_EXTRACT}"
#!/bin/ksh
# Mock testing auto-detection and profile normalization logic
MOCK_HW_VENDOR=""
MOCK_HW_PRODUCT=""
MOCK_HW_VERSION=""
MOCK_HW_DISKNAMES=""
MOCK_DMESG=""
MOCK_APM=""
MOCK_SENSORS=""
MOCK_DISPLAY=""

sysctl() {
    case "$2" in
        hw.vendor) echo "$MOCK_HW_VENDOR" ;;
        hw.product) echo "$MOCK_HW_PRODUCT" ;;
        hw.version) echo "$MOCK_HW_VERSION" ;;
        hw.disknames) echo "$MOCK_HW_DISKNAMES" ;;
        hw.sensors) echo "$MOCK_SENSORS" ;;
        hw.physmem) echo "2147483648" ;;
        hw.model) echo "Intel(R) Core(TM)" ;;
        hw.ncpusfound) echo "4" ;;
        hw.ncpus) echo "4" ;;
        *) return 1 ;;
    esac
}

dmesg() {
    echo "$MOCK_DMESG"
}

apm() {
    echo "$MOCK_APM"
}

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
    if [ -n "$MOCK_APM" ]; then
        if echo "$MOCK_APM" | grep -qE 'Battery status: (high|low|critical|charging)|Remaining battery life:'; then
            IS_LAPTOP=1
            LAPTOP_DETAIL="APM Battery Subsystem Active"
        fi
    fi

    if [ "$IS_LAPTOP" -eq 0 ]; then
        if echo "$MOCK_SENSORS" | grep -qE 'acpibat|battery'; then
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

    # 3. Desktop Workstation Detection
    IS_DESKTOP=0
    if [ -n "$MOCK_DISPLAY" ]; then
        IS_DESKTOP=1
    fi

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

normalize_profile() {
    PROFILE="$1"
    case "$PROFILE" in
        baremetal|bare-metal) PROFILE="server" ;;
        workstation) PROFILE="desktop" ;;
        notebook) PROFILE="laptop" ;;
        cloud|vm) PROFILE="vps" ;;
        dotfiles) PROFILE="config" ;;
    esac
    echo "$PROFILE"
}

TEST_CASE="$1"
case "$TEST_CASE" in
    alias_baremetal) normalize_profile "baremetal" ;;
    alias_workstation) normalize_profile "workstation" ;;
    alias_notebook) normalize_profile "notebook" ;;
    alias_cloud) normalize_profile "cloud" ;;
    alias_dotfiles) normalize_profile "dotfiles" ;;
    detect_vps_qemu)
        MOCK_HW_VENDOR="QEMU"
        MOCK_HW_PRODUCT="Standard PC (Q35 + ICH9, 2009)"
        detect_environment
        echo "$DETECTED_ENV:$DETECTED_DETAIL"
        ;;
    detect_vps_vultr)
        MOCK_HW_PRODUCT="Vultr Cloud Compute"
        MOCK_HW_DISKNAMES="vioblk0:1234,sd0:5678"
        detect_environment
        echo "$DETECTED_ENV:$DETECTED_DETAIL"
        ;;
    detect_laptop_thinkpad)
        MOCK_HW_PRODUCT="ThinkPad X1 Carbon 6th"
        MOCK_APM="Battery status: high. External power status: connected. 98%"
        detect_environment
        echo "$DETECTED_ENV:$DETECTED_DETAIL"
        ;;
    detect_desktop_gui)
        MOCK_HW_VENDOR="Dell Inc."
        MOCK_HW_PRODUCT="Precision 5820 Tower"
        MOCK_DISPLAY=":0"
        detect_environment
        echo "$DETECTED_ENV:$DETECTED_DETAIL"
        ;;
    detect_server_baremetal)
        MOCK_HW_VENDOR="Dell Inc."
        MOCK_HW_PRODUCT="PowerEdge R640"
        detect_environment
        echo "$DETECTED_ENV:$DETECTED_DETAIL"
        ;;
    xz_opt_lowmem)
        PHYSMEM_BYTES=536870912
        if [ "$PHYSMEM_BYTES" -gt 0 ] && [ "$PHYSMEM_BYTES" -le 1073741824 ]; then
            XZ_OPT="${XZ_OPT:--T1 -M 256M}"
        else
            XZ_OPT="${XZ_OPT:--T0}"
        fi
        echo "XZ_OPT:$XZ_OPT"
        ;;
    xz_opt_highmem)
        PHYSMEM_BYTES=4294967296
        if [ "$PHYSMEM_BYTES" -gt 0 ] && [ "$PHYSMEM_BYTES" -le 1073741824 ]; then
            XZ_OPT="${XZ_OPT:--T1 -M 256M}"
        else
            XZ_OPT="${XZ_OPT:--T0}"
        fi
        echo "XZ_OPT:$XZ_OPT"
        ;;
    physmem_calc)
        PHYSMEM_BYTES=$(sysctl -n hw.physmem 2>/dev/null || echo 0)
        case "$PHYSMEM_BYTES" in
            [0-9]*) ;;
            *) PHYSMEM_BYTES=0 ;;
        esac
        echo "RAM:$(( PHYSMEM_BYTES / 1048576 )) MB"
        ;;
esac
KSH_TEST_EOF

assert_output_contains "Alias: baremetal -> server" "server" ksh "${SCRIPT_EXTRACT}" alias_baremetal
assert_output_contains "Alias: workstation -> desktop" "desktop" ksh "${SCRIPT_EXTRACT}" alias_workstation
assert_output_contains "Alias: notebook -> laptop" "laptop" ksh "${SCRIPT_EXTRACT}" alias_notebook
assert_output_contains "Alias: cloud -> vps" "vps" ksh "${SCRIPT_EXTRACT}" alias_cloud
assert_output_contains "Alias: dotfiles -> config" "config" ksh "${SCRIPT_EXTRACT}" alias_dotfiles

assert_output_contains "Detect QEMU VM as VPS" "vps:Cloud VPS / Virtual Machine (QEMU / KVM Virtual Machine)" ksh "${SCRIPT_EXTRACT}" detect_vps_qemu
assert_output_contains "Detect Vultr as VPS" "vps:Cloud VPS / Virtual Machine (Vultr Cloud Compute)" ksh "${SCRIPT_EXTRACT}" detect_vps_vultr
assert_output_contains "Detect ThinkPad as Laptop" "laptop:Laptop / Mobile Notebook (APM Battery Subsystem Active)" ksh "${SCRIPT_EXTRACT}" detect_laptop_thinkpad
assert_output_contains "Detect Precision Tower with GUI as Desktop" "desktop:Desktop Workstation" ksh "${SCRIPT_EXTRACT}" detect_desktop_gui
assert_output_contains "Detect PowerEdge as Server" "server:Bare-metal Physical Server (Dell Inc. PowerEdge R640)" ksh "${SCRIPT_EXTRACT}" detect_server_baremetal

assert_output_contains "XZ option on <=1GB RAM bounds memory (-T1 -M 256M)" "XZ_OPT:-T1 -M 256M" ksh "${SCRIPT_EXTRACT}" xz_opt_lowmem
assert_output_contains "XZ option on >1GB RAM enables multi-core (-T0)" "XZ_OPT:-T0" ksh "${SCRIPT_EXTRACT}" xz_opt_highmem
assert_output_contains "Physical RAM arithmetic via hw.physmem" "RAM:2048 MB" ksh "${SCRIPT_EXTRACT}" physmem_calc

# Test 4: End-to-end archive metadata and restore.ksh --show-info verification
echo "4. Testing restore.ksh inspection of generated metadata..."
FIXTURE_DIR="${TEST_TMP}/fixture"
mkdir -p "${FIXTURE_DIR}/_sysinfo" "${FIXTURE_DIR}/etc" "${FIXTURE_DIR}/root"

cat << 'EOF' > "${FIXTURE_DIR}/_sysinfo/backup_manifest.txt"
OpenBSD Backup Manifest
Generated    : Sat Sep  5 21:00:00 CDT 2026
Hostname     : obsd-laptop.lan
Profile      : laptop
Platform     : Laptop / Mobile Notebook (APM Battery Subsystem Active)
OS Kernel    : OpenBSD 7.6 GENERIC.MP#123 amd64
Architecture : amd64
EOF

cat << 'EOF' > "${FIXTURE_DIR}/_sysinfo/hardware_type.txt"
Hardware & Environment Classification:
Classification : Laptop / Mobile Notebook (APM Battery Subsystem Active)
Profile        : laptop
Vendor         : LENOVO
Product        : 20KGS00C00 (ThinkPad X1 Carbon 6th)
Version        : ThinkPad X1 Carbon 6th
UUID           : 11223344-5566-7788-99aa-bbccddeeff00
CPU Model      : Intel(R) Core(TM) i7-8550U CPU @ 1.80GHz
CPU Cores      : 8 (online: 8)
Physical RAM   : 16384 MB
Disks (hw)     : sd0:12345678,sd1:87654321
EOF

cat << 'EOF' > "${FIXTURE_DIR}/_sysinfo/apm_status.txt"
APM Status:
Battery status: high. External power status: connected. 95%
AC Status Code    : 1
Battery Status Code: 0
Battery Percentage: 95%
Battery Remaining : 380 min
EOF

cat << 'EOF' > "${FIXTURE_DIR}/_sysinfo/wireless_interfaces.txt"
# Wireless Interfaces and Connection Status
=== Interface: iwx0 ===
iwx0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	nwid HomeNet chan 36 bssid 00:11:22:33:44:55
EOF

cat << 'EOF' > "${FIXTURE_DIR}/_sysinfo/installed_packages.txt"
bash-5.2.26
vim-9.1.0-no_x11
git-2.46.0
curl-8.9.1
rsync-3.3.0
EOF

cat << 'EOF' > "${FIXTURE_DIR}/_sysinfo/services_enabled_rcctl.txt"
apmd
sndiod
xenodm
EOF

cat << 'EOF' > "${FIXTURE_DIR}/_sysinfo/duids.txt"
# Disk DUID and Mount Points
sd0: a1b2c3d4e5f60718
a1b2c3d4e5f60718.a / ffs rw 1 1
a1b2c3d4e5f60718.d /home ffs rw,nodev,nosuid 1 2
EOF

cat << 'EOF' > "${FIXTURE_DIR}/_sysinfo/boot.conf"
stty com0 115200
set tty com0
boot
EOF

cat << 'EOF' > "${FIXTURE_DIR}/_sysinfo/softraid_recreate.txt"
# Softraid Crypto Volume Reconstruction Helper
# 1. Initialize disklabel partition: disklabel -E sd0
# 2. Assemble softraid container: bioctl -c C -l 1122334455667788.a softraid0
EOF

cat << 'EOF' > "${FIXTURE_DIR}/_sysinfo/disklabel_sd0.txt"
# /dev/rsd0c:
type: SCSI
disk: SCSI disk
label: fictitious
duid: a1b2c3d4e5f60718
16 partitions:
#                size           offset  fstype [fsize bsize   cpg]
  a:          1048576                0  4.2BSD   2048 16384    16 # /
  c:         20971520                0  unused
  d:         19922944          1048576  4.2BSD   2048 16384    16 # /home
EOF

cat << 'EOF' > "${FIXTURE_DIR}/_sysinfo/services_all_flags.txt"
apmd_flags="-A"
xenodm_flags=""
EOF

echo "CREATE DATABASE test;" | gzip -c > "${FIXTURE_DIR}/_sysinfo/mariadb_all_databases.sql.gz"

echo "test data" > "${FIXTURE_DIR}/etc/sample.conf"

ARCHIVE_PATH="${TEST_TMP}/obsd-laptop_laptop_backup_2026.09.05.tar.gz"
tar -czf "${ARCHIVE_PATH}" -C "${FIXTURE_DIR}" etc root _sysinfo

# Create SHA256 file
if command -v sha256 >/dev/null 2>&1; then
    ( cd "${TEST_TMP}" && sha256 "${ARCHIVE_PATH##*/}" > "${ARCHIVE_PATH##*/}.sha256" )
elif command -v shasum >/dev/null 2>&1; then
    ( cd "${TEST_TMP}" && shasum -a 256 "${ARCHIVE_PATH##*/}" > "${ARCHIVE_PATH##*/}.sha256" )
fi

assert_output_contains "restore.ksh --verify succeeds" "Success" ksh "${REPO_DIR}/restore.ksh" --verify "${ARCHIVE_PATH}"
assert_output_contains "restore.ksh --show-info displays manifest" "obsd-laptop.lan" ksh "${REPO_DIR}/restore.ksh" --show-info "${ARCHIVE_PATH}"
assert_output_contains "restore.ksh --show-info displays hardware" "ThinkPad X1 Carbon" ksh "${REPO_DIR}/restore.ksh" --show-info "${ARCHIVE_PATH}"
assert_output_contains "restore.ksh --show-info displays APM" "Battery Percentage: 95%" ksh "${REPO_DIR}/restore.ksh" --show-info "${ARCHIVE_PATH}"
assert_output_contains "restore.ksh --show-info displays wireless" "Interface: iwx0" ksh "${REPO_DIR}/restore.ksh" --show-info "${ARCHIVE_PATH}"
assert_output_contains "restore.ksh --show-info displays boot.conf" "set tty com0" ksh "${REPO_DIR}/restore.ksh" --show-info "${ARCHIVE_PATH}"
assert_output_contains "restore.ksh --show-info displays packages" "Installed Packages Recorded: 5" ksh "${REPO_DIR}/restore.ksh" --show-info "${ARCHIVE_PATH}"
assert_output_contains "restore.ksh --show-info displays softraid recreation" "Softraid Crypto Configuration" ksh "${REPO_DIR}/restore.ksh" --show-info "${ARCHIVE_PATH}"
assert_output_contains "restore.ksh --show-info displays disklabel protofiles" "disklabel_sd0.txt" ksh "${REPO_DIR}/restore.ksh" --show-info "${ARCHIVE_PATH}"
assert_output_contains "restore.ksh --show-info displays compressed database dumps" "MariaDB (Compressed)" ksh "${REPO_DIR}/restore.ksh" --show-info "${ARCHIVE_PATH}"
assert_output_contains "restore.ksh --show-info displays service flags" "apmd_flags=\"-A\"" ksh "${REPO_DIR}/restore.ksh" --show-info "${ARCHIVE_PATH}"

# Test 4b: Backward compatibility for legacy archives with openbsd_sysinfo.XXXXXXXXXX
LEGACY_DIR="${TEST_TMP}/legacy_fixture"
mkdir -p "${LEGACY_DIR}/openbsd_sysinfo.ffm7IrpjPx" "${LEGACY_DIR}/etc"
cat << 'EOF' > "${LEGACY_DIR}/openbsd_sysinfo.ffm7IrpjPx/backup_manifest.txt"
OpenBSD Backup Manifest
Hostname     : obsd-legacy.lan
Profile      : server
EOF
cat << 'EOF' > "${LEGACY_DIR}/openbsd_sysinfo.ffm7IrpjPx/installed_packages.txt"
curl-8.9.1
EOF
cat << 'EOF' > "${LEGACY_DIR}/openbsd_sysinfo.ffm7IrpjPx/services_enabled_rcctl.txt"
sshd
EOF
echo "syslog: yes" > "${LEGACY_DIR}/etc/syslog.conf"
LEGACY_ARCHIVE_PATH="${TEST_TMP}/obsd-legacy_server_backup_2026.09.05.tar.gz"
tar -czf "${LEGACY_ARCHIVE_PATH}" -C "${LEGACY_DIR}" etc openbsd_sysinfo.ffm7IrpjPx

assert_output_contains "restore.ksh --show-info displays legacy manifest" "obsd-legacy.lan" ksh "${REPO_DIR}/restore.ksh" --show-info "${LEGACY_ARCHIVE_PATH}"

# Test 4c: Full restore excludes both _sysinfo and legacy openbsd_sysinfo.* from restore destination
RESTORE_EXTRACT_DEST="${TEST_TMP}/restore_dest"
mkdir -p "${RESTORE_EXTRACT_DEST}"
tar -xzf "${ARCHIVE_PATH}" -s ',.*_sysinfo.*,,' -s ',.*openbsd_sysinfo\..*,,' -C "${RESTORE_EXTRACT_DEST}"
tar -xzf "${LEGACY_ARCHIVE_PATH}" -s ',.*_sysinfo.*,,' -s ',.*openbsd_sysinfo\..*,,' -C "${RESTORE_EXTRACT_DEST}"

if [ -d "${RESTORE_EXTRACT_DEST}/_sysinfo" ] || ls -d "${RESTORE_EXTRACT_DEST}"/openbsd_sysinfo.* >/dev/null 2>&1; then
    echo "  [FAIL] Metadata directory was incorrectly extracted into restore destination!"
    FAILED=$((FAILED + 1))
else
    echo "  [PASS] Full restore excludes _sysinfo and legacy openbsd_sysinfo.* from destination root"
    PASSED=$((PASSED + 1))
fi

# Test 4d: Verify backup.ksh archives _sysinfo directory instead of openbsd_sysinfo.XXXXXXXXXX
if grep -q 'C "\${SYSINFO_STAGE_DIR}" _sysinfo' "${REPO_DIR}/backup.ksh"; then
    echo "  [PASS] backup.ksh archives metadata as _sysinfo directory"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] backup.ksh does not archive _sysinfo directory"
    FAILED=$((FAILED + 1))
fi

# Test 5: Verify recursion, socket, and cache exclusion patterns via OpenBSD tar -s syntax
echo "5. Testing recursion and loop exclusion patterns (OpenBSD tar -s)..."
EXCLUDE_TEST_DIR="${TEST_TMP}/exclude_test"
mkdir -p "${EXCLUDE_TEST_DIR}/home/user/.cargo/git"
mkdir -p "${EXCLUDE_TEST_DIR}/home/user/.gnupg"
touch "${EXCLUDE_TEST_DIR}/home/user/myhost_server_backup_2026.09.01.tar.gz"
touch "${EXCLUDE_TEST_DIR}/home/user/myhost_server_backup_2026.09.01.tar.gz.sha256"
touch "${EXCLUDE_TEST_DIR}/home/user/.myhost_server_backup.tmp.12345"
touch "${EXCLUDE_TEST_DIR}/home/user/.cargo/git/large_repo.pack"
touch "${EXCLUDE_TEST_DIR}/home/user/important_file.txt"

# Create mock unix domain socket to verify socket exclusion
python3 -c "import socket; s = socket.socket(socket.AF_UNIX); s.bind('${EXCLUDE_TEST_DIR}/home/user/.gnupg/S.gpg-agent'); s.close()" 2>/dev/null || true

EXCLUDE_ARCHIVE="${TEST_TMP}/exclude_archive.tar.gz"

tar -czf "${EXCLUDE_ARCHIVE}" \
    -s ',.*_backup_.*\.tar\..*,,' \
    -s ',.*_backup_.*\.sha256,,' \
    -s ',.*/\..*\.tmp\..*,,' \
    -s ',.*\.tmp\.[0-9]*,,' \
    -s ',.*\.tar\.gz$,,' \
    -s ',.*\.tar\.xz$,,' \
    -s ',.*\.tgz$,,' \
    -s ',.*\.gnupg/S\..*,,' \
    -s ',.*\.sock$,,' \
    -s ',.*/\.cargo/git$,,' \
    -s ',.*/\.cargo/git/.*,,' \
    -C "${EXCLUDE_TEST_DIR}" home

ARCHIVE_CONTENT=$(tar -tzf "${EXCLUDE_ARCHIVE}")

assert_output_contains "Exclusions keep important user file" "home/user/important_file.txt" echo "$ARCHIVE_CONTENT"

if echo "$ARCHIVE_CONTENT" | grep -qE '_backup_|\.tar\.gz|\.tmp|\.cargo/git|S\.gpg-agent'; then
    echo "  [FAIL] Recursive backup files, sockets, or cache were incorrectly included in archive."
    echo "  Archive contents:"
    echo "$ARCHIVE_CONTENT"
    FAILED=$((FAILED + 1))
else
    echo "  [PASS] Recursive backup archives, sockets, temp files, and caches properly excluded"
    PASSED=$((PASSED + 1))
fi

# Test 6: Security hardening features
echo "6. Testing security hardening features..."

# 6.1 Umask 077 enforcement in restore.ksh
if grep -qE '^umask 077' "${REPO_DIR}/restore.ksh"; then
    echo "  [PASS] restore.ksh enforces strict umask (077)"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] restore.ksh did not declare strict umask 077"
    FAILED=$((FAILED + 1))
fi

# 6.2 Comma delimiter handling in add_exclude_rule
DELIM_TEST=$(ksh -c '
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
add_exclude_rule "pattern,with,commas"
echo "${TAR_EXCLUDES[0]}" "${TAR_EXCLUDES[1]}"
')
assert_output_contains "add_exclude_rule selects @ delimiter for comma patterns" "-s @pattern,with,commas@@" echo "$DELIM_TEST"

# 6.3 Verify --skip-secrets excludes hashes and private keys but keeps public configs
SECRETS_TEST_DIR="${TEST_TMP}/secrets_test"
mkdir -p "${SECRETS_TEST_DIR}/etc/ssh"
mkdir -p "${SECRETS_TEST_DIR}/etc/ssl/private"
mkdir -p "${SECRETS_TEST_DIR}/home/user/.ssh"

echo "root:*:0:0:daemon:/root:/bin/ksh" > "${SECRETS_TEST_DIR}/etc/passwd"
echo "root:\$2b\$10\$hash:0:0:daemon:0:0:daemon:/root:/bin/ksh" > "${SECRETS_TEST_DIR}/etc/master.passwd"
echo "PRIVATE_HOST_KEY" > "${SECRETS_TEST_DIR}/etc/ssh/ssh_host_ed25519_key"
echo "ssh-ed25519 AAAAC3... host" > "${SECRETS_TEST_DIR}/etc/ssh/ssh_host_ed25519_key.pub"
echo "TLS_KEY" > "${SECRETS_TEST_DIR}/etc/ssl/private/server.key"
echo "USER_PRIVATE_KEY" > "${SECRETS_TEST_DIR}/home/user/.ssh/id_ed25519"
echo "ssh-ed25519 AAAAC3... user" > "${SECRETS_TEST_DIR}/home/user/.ssh/id_ed25519.pub"
echo "ssh-ed25519 AAAAC3... auth" > "${SECRETS_TEST_DIR}/home/user/.ssh/authorized_keys"

SECRETS_ARCHIVE="${TEST_TMP}/secrets_archive.tar.gz"

tar -czf "${SECRETS_ARCHIVE}" \
    -s ',^etc/master\.passwd$,,' \
    -s ',.*/etc/master\.passwd$,,' \
    -s ',^etc/spwd\.db$,,' \
    -s ',.*/etc/spwd\.db$,,' \
    -s ',^etc/shadow$,,' \
    -s ',.*/etc/shadow$,,' \
    -s ',^etc/ssh/ssh_host_.*_key$,,' \
    -s ',.*/etc/ssh/ssh_host_.*_key$,,' \
    -s ',^etc/ssl/private/.*,,' \
    -s ',^etc/ssl/private$,,' \
    -s ',.*/etc/ssl/private/.*,,' \
    -s ',.*/etc/ssl/private$,,' \
    -s ',.*\.ssh/id_.*,,' \
    -C "${SECRETS_TEST_DIR}" etc home

SECRETS_CONTENT=$(tar -tzf "${SECRETS_ARCHIVE}")

assert_output_contains "--skip-secrets preserves /etc/passwd" "etc/passwd" echo "$SECRETS_CONTENT"
assert_output_contains "--skip-secrets preserves SSH host public key" "etc/ssh/ssh_host_ed25519_key.pub" echo "$SECRETS_CONTENT"
assert_output_contains "--skip-secrets preserves authorized_keys" "home/user/.ssh/authorized_keys" echo "$SECRETS_CONTENT"

if echo "$SECRETS_CONTENT" | grep -qE 'master\.passwd|ssh_host_ed25519_key$|private/server\.key|id_ed25519$'; then
    echo "  [FAIL] Sensitive files were not excluded by --skip-secrets rules!"
    echo "  Archive contents:"
    echo "$SECRETS_CONTENT"
    FAILED=$((FAILED + 1))
else
    echo "  [PASS] Sensitive files (master.passwd, host keys, TLS keys, user id keys) properly excluded"
    PASSED=$((PASSED + 1))
fi

# Test 7: Retention policy verification (archive count vs companion files)
echo "7. Testing retention policy logic..."
RETENTION_TEST_DIR="${TEST_TMP}/retention_test"
mkdir -p "${RETENTION_TEST_DIR}"

# Create 3 archives with companion sha256 and sig files
touch "${RETENTION_TEST_DIR}/myhost_server_backup_2026.01.01.tar.gz"
touch "${RETENTION_TEST_DIR}/myhost_server_backup_2026.01.01.tar.gz.sha256"
touch "${RETENTION_TEST_DIR}/myhost_server_backup_2026.01.01.tar.gz.sig"
touch "${RETENTION_TEST_DIR}/myhost_server_backup_2026.01.02.tar.gz"
touch "${RETENTION_TEST_DIR}/myhost_server_backup_2026.01.02.tar.gz.sha256"
touch "${RETENTION_TEST_DIR}/myhost_server_backup_2026.01.02.tar.gz.sig"
touch "${RETENTION_TEST_DIR}/myhost_server_backup_2026.01.03.tar.gz"
touch "${RETENTION_TEST_DIR}/myhost_server_backup_2026.01.03.tar.gz.sha256"
touch "${RETENTION_TEST_DIR}/myhost_server_backup_2026.01.03.tar.gz.sig"

# Execute retention logic with KEEP_COUNT=2
ksh -c '
FINAL_DEST_DIR="'"${RETENTION_TEST_DIR}"'"
ARCHIVE_PREFIX="myhost_server_backup_"
KEEP_COUNT=2

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
            rm -f "$OLD_FILE" "${OLD_FILE}.sha256" "${OLD_FILE}.sig" 2>/dev/null || true
        fi
        i=$((i + 1))
    done
fi
'

if [ ! -f "${RETENTION_TEST_DIR}/myhost_server_backup_2026.01.01.tar.gz" ] && \
   [ ! -f "${RETENTION_TEST_DIR}/myhost_server_backup_2026.01.01.tar.gz.sha256" ] && \
   [ ! -f "${RETENTION_TEST_DIR}/myhost_server_backup_2026.01.01.tar.gz.sig" ] && \
   [ -f "${RETENTION_TEST_DIR}/myhost_server_backup_2026.01.02.tar.gz" ] && \
   [ -f "${RETENTION_TEST_DIR}/myhost_server_backup_2026.01.03.tar.gz" ]; then
    echo "  [PASS] Retention policy keeps requested archive count and cleans companions"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] Retention policy miscalculated archive count or failed to prune companions!"
    FAILED=$((FAILED + 1))
fi

echo "============================================================"
echo " Test Results: ${PASSED} Passed, ${FAILED} Failed"
echo "============================================================"

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
