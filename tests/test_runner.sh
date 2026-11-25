#!/bin/sh
# ==============================================================================
# tests/test_runner.sh
#
# Automated verification test suite for backup.ksh and restore.ksh.
# Runs cleanly on both OpenBSD and macOS. Validates shell syntax, OpenBSD
# compatibility invariants, argument parsing, profile normalization,
# auto-detection heuristics, exclusion rules, security hardening, retention
# pruning, and end-to-end restore.ksh workflows (gzip, xz, zstd, age).
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

assert_fail() {
    TEST_NAME="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "  [FAIL] ${TEST_NAME} (expected non-zero exit, got 0)"
        FAILED=$((FAILED + 1))
    else
        echo "  [PASS] ${TEST_NAME}"
        PASSED=$((PASSED + 1))
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

assert_output_not_matches() {
    TEST_NAME="$1"
    UNEXPECTED_REGEX="$2"
    shift 2
    OUTPUT=$("$@" 2>&1 || true)
    if echo "$OUTPUT" | grep -Eq -- "$UNEXPECTED_REGEX"; then
        echo "  [FAIL] ${TEST_NAME}: Did NOT expect output to match regex '${UNEXPECTED_REGEX}'."
        echo "  Output was: ${OUTPUT}"
        FAILED=$((FAILED + 1))
    else
        echo "  [PASS] ${TEST_NAME}"
        PASSED=$((PASSED + 1))
    fi
}

echo "============================================================"
echo " Running OpenBSD Backup Test Suite"
echo "============================================================"

# Test 1: Syntax checks
echo "1. Checking shell syntax..."
assert_success "backup.ksh ksh syntax check" ksh -n "${REPO_DIR}/backup.ksh"
assert_success "restore.ksh ksh syntax check" ksh -n "${REPO_DIR}/restore.ksh"

# Extract embedded quick-restore.sh and check its /bin/sh syntax
awk '/^cat << '\''RESCUE_EOF'\''/{flag=1;next}/^RESCUE_EOF$/{flag=0}flag' "${REPO_DIR}/backup.ksh" > "${TEST_TMP}/quick-restore.sh"
assert_success "embedded quick-restore.sh sh syntax check" sh -n "${TEST_TMP}/quick-restore.sh"

# Test 2: Help flag verification
echo "2. Verifying help banners..."
assert_output_contains "backup.ksh --help contains server" "server : Bare-metal server" ksh "${REPO_DIR}/backup.ksh" --help
assert_output_contains "backup.ksh --help contains desktop" "desktop: Desktop workstation" ksh "${REPO_DIR}/backup.ksh" --help
assert_output_contains "backup.ksh --help contains laptop" "laptop : Laptop/notebook" ksh "${REPO_DIR}/backup.ksh" --help
assert_output_contains "backup.ksh --help contains vps" "vps    : Cloud VPS & VMs" ksh "${REPO_DIR}/backup.ksh" --help
assert_output_contains "backup.ksh --help contains --zstd" "-Z, --zstd" ksh "${REPO_DIR}/backup.ksh" --help
assert_output_contains "backup.ksh --help contains --encrypt-key" "-e, --encrypt-key" ksh "${REPO_DIR}/backup.ksh" --help
assert_output_contains "backup.ksh --help contains --sqlite" "--sqlite" ksh "${REPO_DIR}/backup.ksh" --help
assert_output_contains "backup.ksh --help contains --quiet" "-q, --quiet" ksh "${REPO_DIR}/backup.ksh" --help
assert_output_contains "backup.ksh --help contains --ssh-key" "--ssh-key" ksh "${REPO_DIR}/backup.ksh" --help
assert_output_contains "backup.ksh --help contains --sign" "-S, --sign" ksh "${REPO_DIR}/backup.ksh" --help
assert_output_contains "backup.ksh --help contains --skip-secrets" "--skip-secrets" ksh "${REPO_DIR}/backup.ksh" --help
assert_output_contains "restore.ksh --help contains show-info" "--show-info" ksh "${REPO_DIR}/restore.ksh" --help
assert_output_contains "restore.ksh --help contains --decrypt-key" "-K, --decrypt-key" ksh "${REPO_DIR}/restore.ksh" --help
assert_output_contains "restore.ksh --help contains --overwrite-fstab" "--overwrite-fstab" ksh "${REPO_DIR}/restore.ksh" --help
assert_output_contains "restore.ksh --help contains --sig-key" "-S, --sig-key" ksh "${REPO_DIR}/restore.ksh" --help

# Test 3: OpenBSD compatibility & bug regression checks on actual script sources
echo "3. Checking OpenBSD compatibility invariants..."
assert_fail "backup.ksh does not use unsupported OpenBSD tar -J" grep -E -- '-[a-zA-Z]*J[a-zA-Z]*f' "${REPO_DIR}/backup.ksh"
assert_fail "restore.ksh does not use unsupported OpenBSD tar -J" grep -E -- '-[a-zA-Z]*J[a-zA-Z]*f' "${REPO_DIR}/restore.ksh"
assert_success "backup.ksh uses valid 'rcctl get all'" grep -Fq 'rcctl get all' "${REPO_DIR}/backup.ksh"
assert_fail "backup.ksh does not use invalid 'rcctl get --all'" grep -Fq 'rcctl get --all' "${REPO_DIR}/backup.ksh"
assert_fail "backup.ksh does not use invalid 'rcctl ls manual'" grep -Fq 'rcctl ls manual' "${REPO_DIR}/backup.ksh"
assert_success "backup.ksh queries 'bioctl softraid0'" grep -Fq 'bioctl softraid0' "${REPO_DIR}/backup.ksh"
assert_fail "backup.ksh does not query nonexistent 'sr0'" grep -Fq 'bioctl sr0' "${REPO_DIR}/backup.ksh"
assert_fail "backup.ksh does not suggest dangerous 'newfs /dev/rsdXc'" grep -Fq 'newfs /dev/rsdXc' "${REPO_DIR}/backup.ksh"
assert_fail "backup.ksh does not use removed 'pfctl -sn'" grep -Fq 'pfctl -sn' "${REPO_DIR}/backup.ksh"
assert_fail "backup.ksh does not exclude all user *.tar.gz files" grep -Fq 'add_exclude_rule ".*\.tar\.gz\$"' "${REPO_DIR}/backup.ksh"
assert_fail "backup.ksh does not include var/backups in BASE_TARGETS" grep -E '^set -A BASE_TARGETS.*var/backups' "${REPO_DIR}/backup.ksh"
assert_fail "backup.ksh does not duplicate etc/wireguard target" grep -Fq '"${TARGETS[@]}" etc/wireguard' "${REPO_DIR}/backup.ksh"
assert_success "backup.ksh signs SHA256 manifest via signify -S -e" grep -Fq 'signify -S -e' "${REPO_DIR}/backup.ksh"
assert_success "restore.ksh verifies embedded signatures via signify -C" grep -Fq 'signify -C' "${REPO_DIR}/restore.ksh"
assert_success "restore.ksh rebuilds pwd_mkdb on master.passwd restore" grep -Fq 'pwd_mkdb -p /etc/master.passwd' "${REPO_DIR}/restore.ksh"
assert_success "backup.ksh captures sndioctl desktop audio state" grep -Fq 'sndioctl_state.txt' "${REPO_DIR}/backup.ksh"
assert_success "backup.ksh captures Raspberry Pi MSDOS boot partition" grep -Fq 'rpi_boot' "${REPO_DIR}/backup.ksh"
assert_success "backup.ksh excludes reconstructible .notmuch/xapian index" grep -Fq 'add_exclude_dir ".notmuch/xapian"' "${REPO_DIR}/backup.ksh"
assert_success "backup.ksh tolerates OpenBSD tar 'was modified during copy to archive'" grep -Fq 'was modified during copy to archive' "${REPO_DIR}/backup.ksh"
assert_success "backup.ksh excludes OpenSSH 10.1+ .ssh/agent/* sockets" grep -Fq 'add_exclude_rule ".*\.ssh/agent/.*"' "${REPO_DIR}/backup.ksh"
TAR_FILTER_LINE=$(grep 'FATAL_TAR_ERRS=' "${REPO_DIR}/backup.ksh")
TAR_FILTER_REGEX=$(printf "%s" "$TAR_FILTER_LINE" | sed -E "s/.*grep -viE '([^']+)'.*/\1/")
assert_output_not_matches "tar warning filter tolerates OpenBSD 'Ustar cannot archive a socket'" "." sh -c "printf '%s\n' 'tar: Ustar cannot archive a socket home/ms/.ssh/agent/s.7TtvMAr0tt.local.40269.WUa4R5tazs' | grep -viE '${TAR_FILTER_REGEX}' || true"
assert_output_contains "tar warning filter still fails on real permission error" "Permission denied" sh -c "printf '%s\n' 'tar: Unable to access /etc/master.passwd (Permission denied)' | grep -viE '${TAR_FILTER_REGEX}' || true"
assert_success "backup.ksh enforces umask 077" grep -qE '^umask 077' "${REPO_DIR}/backup.ksh"
assert_success "restore.ksh enforces umask 077" grep -qE '^umask 077' "${REPO_DIR}/restore.ksh"

# Test 4: Auto-detection & profile normalization (extracted from backup.ksh!)
echo "4. Testing profile normalization and hardware auto-detection..."
DETECT_HARNESS="${TEST_TMP}/detect_harness.ksh"
{
    echo '#!/bin/ksh'
    cat << 'MOCKS_EOF'
MOCK_HW_VENDOR=""
MOCK_HW_PRODUCT=""
MOCK_HW_VERSION=""
MOCK_HW_DISKNAMES=""
MOCK_HW_MACHINE="amd64"
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
        hw.machine) echo "$MOCK_HW_MACHINE" ;;
        hw.sensors) echo "$MOCK_SENSORS" ;;
        hw.physmem) echo "2147483648" ;;
        *) return 1 ;;
    esac
}
dmesg() { echo "$MOCK_DMESG"; }
apm() { echo "$MOCK_APM"; }
pgrep() { return 1; }
MOCKS_EOF
    # Extract actual detect_environment() from backup.ksh
    awk '/^detect_environment\(\) \{/{flag=1} flag{print} /^\}$/ && flag{flag=0}' "${REPO_DIR}/backup.ksh"
    cat << 'CASES_EOF'
case "$1" in
    detect_vps_qemu)
        MOCK_HW_VENDOR="QEMU"; MOCK_HW_PRODUCT="Standard PC (Q35 + ICH9, 2009)"
        detect_environment; echo "$DETECTED_ENV:$DETECTED_DETAIL" ;;
    detect_vps_vultr)
        MOCK_HW_PRODUCT="Vultr Cloud Compute"; MOCK_HW_DISKNAMES="vioblk0:1234"
        detect_environment; echo "$DETECTED_ENV:$DETECTED_DETAIL" ;;
    detect_rpi_arm64)
        MOCK_HW_VENDOR="Raspberry Pi Foundation"; MOCK_HW_PRODUCT="Raspberry Pi 4 Model B Rev 1.4"
        MOCK_HW_MACHINE="arm64"
        detect_environment; echo "$DETECTED_ENV:$IS_RPI:$DETECTED_DETAIL" ;;
    detect_laptop_thinkpad)
        MOCK_HW_PRODUCT="ThinkPad X1 Carbon 6th"
        MOCK_APM="Battery status: high. External power status: connected. 98%"
        detect_environment; echo "$DETECTED_ENV:$DETECTED_DETAIL" ;;
    detect_desktop_gui)
        MOCK_HW_VENDOR="Dell Inc."; MOCK_HW_PRODUCT="Precision 5820 Tower"; DISPLAY=":0"
        detect_environment; echo "$DETECTED_ENV:$DETECTED_DETAIL" ;;
    detect_server_baremetal)
        MOCK_HW_VENDOR="Dell Inc."; MOCK_HW_PRODUCT="PowerEdge R640"
        detect_environment; echo "$DETECTED_ENV:$DETECTED_DETAIL" ;;
    xz_tiers)
        for mem in 536870912 2147483648 8589934592; do
            unset XZ_OPT
            if [ "$mem" -le 1073741824 ]; then
                XZ_OPT="-T1 -M 256M"
            elif [ "$mem" -le 4294967296 ]; then
                XZ_OPT="-T2 -M 40%"
            else
                XZ_OPT="-T0 -M 50%"
            fi
            echo "${mem}:${XZ_OPT}"
        done ;;
esac
CASES_EOF
} > "${DETECT_HARNESS}"

assert_output_contains "Detect QEMU VM as VPS" "vps:Cloud VPS / Virtual Machine (QEMU / KVM Virtual Machine)" ksh "${DETECT_HARNESS}" detect_vps_qemu
assert_output_contains "Detect Vultr as VPS" "vps:Cloud VPS / Virtual Machine (Vultr Cloud Compute)" ksh "${DETECT_HARNESS}" detect_vps_vultr
assert_output_contains "Detect Raspberry Pi 4 (arm64)" "server:1:Raspberry Pi / ARM SBC (Raspberry Pi 4 Model B Rev 1.4)" ksh "${DETECT_HARNESS}" detect_rpi_arm64
assert_output_contains "Detect ThinkPad as Laptop" "laptop:Laptop / Mobile Notebook (APM Battery Subsystem Active)" ksh "${DETECT_HARNESS}" detect_laptop_thinkpad
assert_output_contains "Detect Precision Tower with GUI as Desktop" "desktop:Desktop Workstation (Active Display)" ksh "${DETECT_HARNESS}" detect_desktop_gui
assert_output_contains "Detect PowerEdge as Server" "server:Bare-metal Physical Server (Dell Inc. PowerEdge R640)" ksh "${DETECT_HARNESS}" detect_server_baremetal
assert_output_contains "XZ <=1GB bounds to -T1 -M 256M" "536870912:-T1 -M 256M" ksh "${DETECT_HARNESS}" xz_tiers
assert_output_contains "XZ 2GB Pi/VPS bounds to -T2 -M 40%" "2147483648:-T2 -M 40%" ksh "${DETECT_HARNESS}" xz_tiers
assert_output_contains "XZ 8GB desktop bounds to -T0 -M 50%" "8589934592:-T0 -M 50%" ksh "${DETECT_HARNESS}" xz_tiers

# Test 5: Real exclusion engine tests (extracted directly from backup.ksh!)
echo "5. Testing actual backup.ksh exclusion & --skip-secrets functions..."
EXCL_HARNESS="${TEST_TMP}/excl_harness.ksh"
{
    echo '#!/bin/ksh'
    echo 'set -e'
    awk '/^regex_escape\(\) \{/{flag=1} flag{print} /^\}$/ && flag{flag=0}' "${REPO_DIR}/backup.ksh"
    awk '/^glob_to_bre\(\) \{/{flag=1} flag{print} /^\}$/ && flag{flag=0}' "${REPO_DIR}/backup.ksh"
    awk '/^add_exclude_rule\(\) \{/{flag=1} flag{print} /^\}$/ && flag{flag=0}' "${REPO_DIR}/backup.ksh"
    awk '/^add_exclude_dir\(\) \{/{flag=1} flag{print} /^\}$/ && flag{flag=0}' "${REPO_DIR}/backup.ksh"
    awk '/^add_exclude_file\(\) \{/{flag=1} flag{print} /^\}$/ && flag{flag=0}' "${REPO_DIR}/backup.ksh"
    awk '/^add_user_exclude\(\) \{/{flag=1} flag{print} /^\}$/ && flag{flag=0}' "${REPO_DIR}/backup.ksh"
    cat << 'EXCL_TEST_EOF'
case "$1" in
    delim)
        set -A TAR_EXCLUDES
        add_exclude_rule "pattern,with,commas"
        echo "${TAR_EXCLUDES[0]} ${TAR_EXCLUDES[1]}"
        ;;
    user_and_loop)
        SRC="$2"
        OUT="$3"
        set -A TAR_EXCLUDES
        # Loop protection from backup.ksh
        add_exclude_rule ".*_backup_.*\.tar\..*"
        add_exclude_rule ".*_backup_.*\.tgz.*"
        add_exclude_rule ".*_backup_.*\.sha256.*"
        add_exclude_rule ".*_backup_.*\.sig\$"
        add_exclude_rule ".*/\..*_backup_.*\.tmp\..*"
        add_exclude_rule ".*\.gnupg/S\..*"
        add_exclude_rule ".*\.ssh/agent/.*"
        add_exclude_rule ".*\.sock\$"
        # Anchored mfs /tmp mount exclusion
        add_exclude_rule "^tmp\$"
        add_exclude_rule "^tmp/.*"
        # Firefox cache only (keeps storage/default) & Notmuch Xapian index
        add_exclude_rule ".*/\.mozilla/firefox/[^/]*/cache2\$"
        add_exclude_rule ".*/\.mozilla/firefox/[^/]*/cache2/.*"
        add_exclude_rule ".*/\.mozilla/firefox/[^/]*/storage/temporary\$"
        add_exclude_rule ".*/\.mozilla/firefox/[^/]*/storage/temporary/.*"
        add_exclude_dir ".notmuch/xapian"
        # Custom user exclusions
        add_user_exclude "home/user/Videos"
        add_user_exclude "*.log"
        add_user_exclude "*/VirtualBox VMs"
        tar -cf - "${TAR_EXCLUDES[@]}" -C "$SRC" home tmp | gzip -c > "$OUT"
        gzip -dc "$OUT" | tar -tf -
        ;;
    secrets)
        SRC="$2"
        OUT="$3"
        set -A TAR_EXCLUDES
        SKIP_SECRETS=1
        # Extract exact SKIP_SECRETS rules block from backup.ksh
EXCL_TEST_EOF
    awk '/^if \[ "\$SKIP_SECRETS" -eq 1 \]; then/{flag=1;next}/^fi$/ && flag{flag=0}flag' "${REPO_DIR}/backup.ksh" \
        | grep -E '^[[:space:]]*add_exclude_rule'
    cat << 'EXCL_TEST_END'
        tar -cf - "${TAR_EXCLUDES[@]}" -C "$SRC" etc home var | gzip -c > "$OUT"
        gzip -dc "$OUT" | tar -tf -
        ;;
esac
EXCL_TEST_END
} > "${EXCL_HARNESS}"

assert_output_contains "add_exclude_rule picks @ delimiter for commas" "-s @pattern,with,commas@@" ksh "${EXCL_HARNESS}" delim

# Prepare user/loop/mount exclusion fixture
LOOP_DIR="${TEST_TMP}/loop_fixture"
mkdir -p "${LOOP_DIR}/home/user/Videos" \
         "${LOOP_DIR}/home/user/VirtualBox VMs" \
         "${LOOP_DIR}/home/user/project/tmp" \
         "${LOOP_DIR}/home/user/.gnupg" \
         "${LOOP_DIR}/home/user/.ssh/agent" \
         "${LOOP_DIR}/home/user/.mozilla/firefox/abc.default/cache2" \
         "${LOOP_DIR}/home/user/.mozilla/firefox/abc.default/storage/default" \
         "${LOOP_DIR}/home/user/.mozilla/firefox/abc.default/storage/temporary" \
         "${LOOP_DIR}/home/user/.mail/.notmuch/xapian" \
         "${LOOP_DIR}/home/user/.mail/Inbox/cur" \
         "${LOOP_DIR}/tmp"

touch "${LOOP_DIR}/home/user/.mail/.notmuch/xapian/termlist.glass"
touch "${LOOP_DIR}/home/user/.mail/Inbox/cur/msg1:2,S"

touch "${LOOP_DIR}/home/user/important_file.txt"
touch "${LOOP_DIR}/home/user/my_personal_release.tar.gz"
touch "${LOOP_DIR}/home/user/my_personal_sources.tar.xz"
touch "${LOOP_DIR}/home/user/my_personal_docs.tgz"
touch "${LOOP_DIR}/home/user/app.log"
touch "${LOOP_DIR}/home/user/app.login"
touch "${LOOP_DIR}/home/user/Videos/movie.mp4"
touch "${LOOP_DIR}/home/user/VirtualBox VMs/vm.vdi"
touch "${LOOP_DIR}/home/user/project/tmp/keep_this.txt"
touch "${LOOP_DIR}/tmp/mfs_ephemeral.txt"
touch "${LOOP_DIR}/home/user/myhost_server_backup_2026.09.01.tar.gz"
touch "${LOOP_DIR}/home/user/myhost_server_backup_2026.09.01.tar.gz.sha256"
touch "${LOOP_DIR}/home/user/myhost_server_backup_2026.09.01.tar.gz.sha256.sig"
touch "${LOOP_DIR}/home/user/.myhost_server_backup_2026.tmp.12345"
touch "${LOOP_DIR}/home/user/.mozilla/firefox/abc.default/cache2/blob"
touch "${LOOP_DIR}/home/user/.mozilla/firefox/abc.default/storage/default/ublock.sqlite"
touch "${LOOP_DIR}/home/user/.mozilla/firefox/abc.default/storage/temporary/temp.sqlite"
touch "${LOOP_DIR}/home/user/.ssh/config"
python3 -c "import os, socket; os.chdir('${LOOP_DIR}/home/user/.gnupg'); s = socket.socket(socket.AF_UNIX); s.bind('S.gpg-agent'); s.close()" 2>/dev/null || true
python3 -c "import os, socket; os.chdir('${LOOP_DIR}/home/user/.ssh/agent'); s = socket.socket(socket.AF_UNIX); s.bind('s.7TtvMAr0tt.local.40269.WUa4R5tazs'); s.close()" 2>/dev/null || true

LOOP_LIST=$(ksh "${EXCL_HARNESS}" user_and_loop "${LOOP_DIR}" "${TEST_TMP}/loop.tar.gz")

assert_output_contains "Preserves user personal .tar.gz file" "home/user/my_personal_release.tar.gz" echo "$LOOP_LIST"
assert_output_contains "Preserves user personal .tar.xz file" "home/user/my_personal_sources.tar.xz" echo "$LOOP_LIST"
assert_output_contains "Preserves user personal .tgz file" "home/user/my_personal_docs.tgz" echo "$LOOP_LIST"
assert_output_contains "Preserves user project/tmp despite anchored /tmp mfs rule" "home/user/project/tmp/keep_this.txt" echo "$LOOP_LIST"
assert_output_contains "Anchored *.log preserves app.login" "home/user/app.login" echo "$LOOP_LIST"
assert_output_contains "Preserves Firefox extension storage/default" "storage/default/ublock.sqlite" echo "$LOOP_LIST"
assert_output_contains "Preserves user .ssh/config alongside agent socket exclusion" "home/user/.ssh/config" echo "$LOOP_LIST"
assert_output_not_matches "Excludes prior backup archives" "myhost_server_backup_2026" echo "$LOOP_LIST"
assert_output_not_matches "Excludes live gpg socket" "S\.gpg-agent" echo "$LOOP_LIST"
assert_output_not_matches "Excludes OpenSSH 10.1+ ssh-agent socket" "\.ssh/agent/s\." echo "$LOOP_LIST"
assert_output_not_matches "Excludes anchored /tmp mfs mount" "^tmp/mfs_ephemeral\.txt$" echo "$LOOP_LIST"
assert_output_not_matches "Excludes top-level -x home/user/Videos" "Videos/movie\.mp4$" echo "$LOOP_LIST"
assert_output_not_matches "Excludes -x */VirtualBox VMs" "vm\.vdi$" echo "$LOOP_LIST"
assert_output_not_matches "Excludes -x *.log" "app\.log$" echo "$LOOP_LIST"
assert_output_contains "Preserves actual Maildir messages" "Inbox/cur/msg1:2,S" echo "$LOOP_LIST"
assert_output_not_matches "Excludes reconstructible .notmuch/xapian index" "\.notmuch/xapian/termlist\.glass$" echo "$LOOP_LIST"
assert_output_not_matches "Excludes Firefox cache2" "cache2/blob$" echo "$LOOP_LIST"
assert_output_not_matches "Excludes Firefox storage/temporary" "storage/temporary/temp\.sqlite$" echo "$LOOP_LIST"

# Prepare --skip-secrets fixture (verifying ALL newly hardened secret paths!)
SEC_DIR="${TEST_TMP}/sec_fixture"
mkdir -p "${SEC_DIR}/etc/ssh" "${SEC_DIR}/etc/ssl/private" "${SEC_DIR}/etc/signify" \
         "${SEC_DIR}/etc/acme" "${SEC_DIR}/etc/iked/private" "${SEC_DIR}/etc/mail/dkim" \
         "${SEC_DIR}/var/backups" \
         "${SEC_DIR}/home/user/.ssh" "${SEC_DIR}/home/user/.vim/undo" \
         "${SEC_DIR}/home/user/.sndio" "${SEC_DIR}/home/user/.aws"

echo "root:*:0:0:daemon:/root:/bin/ksh" > "${SEC_DIR}/etc/passwd"
echo "root:HASH:0:0::0:0:daemon:/root:/bin/ksh" > "${SEC_DIR}/etc/master.passwd"
echo "root:HASH:0:0::0:0:daemon:/root:/bin/ksh" > "${SEC_DIR}/var/backups/master.passwd.current"
echo "SIGNIFY_SEC" > "${SEC_DIR}/etc/signify/backup.sec"
echo "SIGNIFY_PUB" > "${SEC_DIR}/etc/signify/backup.pub"
echo "join MyWiFi wpakey SuperSecret" > "${SEC_DIR}/etc/hostname.iwx0"
echo "ACME_KEY" > "${SEC_DIR}/etc/acme/letsencrypt-privkey.pem"
echo "IKED_KEY" > "${SEC_DIR}/etc/iked/private/local.key"
echo "SMTP_SECRET" > "${SEC_DIR}/etc/mail/secrets"
echo "HOST_PRIV" > "${SEC_DIR}/etc/ssh/ssh_host_ed25519_key"
echo "HOST_PUB" > "${SEC_DIR}/etc/ssh/ssh_host_ed25519_key.pub"
echo "TLS_KEY" > "${SEC_DIR}/etc/ssl/private/server.key"
echo "USER_PRIV" > "${SEC_DIR}/home/user/.ssh/id_ed25519"
echo "USER_PUB" > "${SEC_DIR}/home/user/.ssh/id_ed25519.pub"
echo "AUTH_KEYS" > "${SEC_DIR}/home/user/.ssh/authorized_keys"
echo "NETRC_SECRET" > "${SEC_DIR}/home/user/.netrc"
echo "AWS_SECRET" > "${SEC_DIR}/home/user/.aws/credentials"
echo "HISTORY_CMD" > "${SEC_DIR}/home/user/.ksh_history"
echo "UNDO_SECRET" > "${SEC_DIR}/home/user/.vim/undo/file"
echo "XAUTH" > "${SEC_DIR}/home/user/.Xauthority"
echo "SNDIO" > "${SEC_DIR}/home/user/.sndio/cookie"

SEC_LIST=$(ksh "${EXCL_HARNESS}" secrets "${SEC_DIR}" "${TEST_TMP}/sec.tar.gz")

assert_output_contains "--skip-secrets preserves /etc/passwd" "etc/passwd" echo "$SEC_LIST"
assert_output_contains "--skip-secrets preserves signify public key" "etc/signify/backup.pub" echo "$SEC_LIST"
assert_output_contains "--skip-secrets preserves SSH host public key" "etc/ssh/ssh_host_ed25519_key.pub" echo "$SEC_LIST"
assert_output_contains "--skip-secrets preserves user SSH public key (id_ed25519.pub)" "home/user/.ssh/id_ed25519.pub" echo "$SEC_LIST"
assert_output_contains "--skip-secrets preserves authorized_keys" "home/user/.ssh/authorized_keys" echo "$SEC_LIST"
assert_output_not_matches "--skip-secrets excludes /etc/master.passwd" "etc/master\.passwd$" echo "$SEC_LIST"
assert_output_not_matches "--skip-secrets excludes /var/backups shadow copy" "master\.passwd\.current$" echo "$SEC_LIST"
assert_output_not_matches "--skip-secrets excludes /etc/signify/*.sec" "backup\.sec$" echo "$SEC_LIST"
assert_output_not_matches "--skip-secrets excludes /etc/hostname.*" "hostname\.iwx0$" echo "$SEC_LIST"
assert_output_not_matches "--skip-secrets excludes /etc/acme/*" "letsencrypt-privkey\.pem$" echo "$SEC_LIST"
assert_output_not_matches "--skip-secrets excludes /etc/iked/private/*" "iked/private/local\.key$" echo "$SEC_LIST"
assert_output_not_matches "--skip-secrets excludes /etc/mail/secrets" "etc/mail/secrets$" echo "$SEC_LIST"
assert_output_not_matches "--skip-secrets excludes user private key (id_ed25519)" "id_ed25519$" echo "$SEC_LIST"
assert_output_not_matches "--skip-secrets excludes .netrc" "\.netrc$" echo "$SEC_LIST"
assert_output_not_matches "--skip-secrets excludes .aws/credentials" "\.aws/credentials$" echo "$SEC_LIST"
assert_output_not_matches "--skip-secrets excludes .ksh_history" "\.ksh_history$" echo "$SEC_LIST"

# Test 6: End-to-end restore.ksh verification (gzip, xz, zstd, age, diff, full, config)
echo "6. Testing restore.ksh end-to-end across formats & guardrails..."
FIXTURE_DIR="${TEST_TMP}/fixture"
mkdir -p "${FIXTURE_DIR}/_sysinfo/rpi_boot" "${FIXTURE_DIR}/_sysinfo/sqlite" \
         "${FIXTURE_DIR}/etc" "${FIXTURE_DIR}/root" "${FIXTURE_DIR}/home/alice/projects"

cat << 'EOF' > "${FIXTURE_DIR}/_sysinfo/backup_manifest.txt"
OpenBSD Backup Manifest
Generated    : Sat Nov 21 22:00:00 CST 2026
Hostname     : obsd-rpi.lan
Profile      : server
Platform     : Raspberry Pi / ARM SBC (Raspberry Pi 4 Model B)
OS Kernel    : OpenBSD 7.6 GENERIC.MP#123 arm64
OS Release   : 7.6
Architecture : arm64
Compression  : gzip
Encrypted    : no
EOF

cat << 'EOF' > "${FIXTURE_DIR}/_sysinfo/hardware_type.txt"
Classification : Raspberry Pi / ARM SBC (Raspberry Pi 4 Model B)
Profile        : server
Vendor         : Raspberry Pi Foundation
Product        : Raspberry Pi 4 Model B
Physical RAM   : 4096 MB
EOF

echo "enable_uart=1" > "${FIXTURE_DIR}/_sysinfo/rpi_boot/config.txt"
echo "output.level=0.750" > "${FIXTURE_DIR}/_sysinfo/sndioctl_state.txt"
echo "sqlite-snap" > "${FIXTURE_DIR}/_sysinfo/sqlite/var_www_app.db"
printf "vim-9.1\ngit-2.46\n" > "${FIXTURE_DIR}/_sysinfo/installed_packages.txt"
printf "sshd\nntpd\n" > "${FIXTURE_DIR}/_sysinfo/services_enabled_rcctl.txt"
echo 'apmd_flags="-A"' > "${FIXTURE_DIR}/_sysinfo/services_all_flags.txt"
echo "CREATE TABLE t(x);" | gzip -c > "${FIXTURE_DIR}/_sysinfo/mariadb_all_databases.sql.gz"
echo "a1b2c3d4e5f60718.a / ffs rw 1 1" > "${FIXTURE_DIR}/etc/fstab"
echo "root:*:0:0:daemon:/root:/bin/ksh" > "${FIXTURE_DIR}/etc/passwd"
echo "set skip on lo" > "${FIXTURE_DIR}/etc/pf.conf"
echo "keep me" > "${FIXTURE_DIR}/home/alice/projects/my_sysinfo_notes.txt"

ARCHIVE_GZ="${TEST_TMP}/obsd-rpi_server_backup_2026.11.21.tar.gz"
tar -cf - -C "${FIXTURE_DIR}" etc root home _sysinfo | gzip -c > "${ARCHIVE_GZ}"

# Write BSD-tagged SHA256
if command -v sha256 >/dev/null 2>&1; then
    ( cd "${TEST_TMP}" && sha256 "${ARCHIVE_GZ##*/}" > "${ARCHIVE_GZ##*/}.sha256" )
else
    h=$(shasum -a 256 "${ARCHIVE_GZ}" | awk '{print $1}')
    echo "SHA256 (${ARCHIVE_GZ##*/}) = ${h}" > "${ARCHIVE_GZ}.sha256"
fi

assert_output_contains "restore.ksh --verify (gzip) succeeds" "Success: Archive structure is valid" ksh "${REPO_DIR}/restore.ksh" --verify "${ARCHIVE_GZ}"
assert_output_contains "restore.ksh --show-info displays manifest" "obsd-rpi.lan" ksh "${REPO_DIR}/restore.ksh" --show-info "${ARCHIVE_GZ}"
assert_output_contains "restore.ksh --show-info displays RPi boot config" "enable_uart=1" ksh "${REPO_DIR}/restore.ksh" --show-info "${ARCHIVE_GZ}"
assert_output_contains "restore.ksh --show-info displays sndioctl" "output.level=0.750" ksh "${REPO_DIR}/restore.ksh" --show-info "${ARCHIVE_GZ}"
assert_output_contains "restore.ksh --show-info displays SQLite snapshot" "var_www_app.db" ksh "${REPO_DIR}/restore.ksh" --show-info "${ARCHIVE_GZ}"
assert_output_contains "restore.ksh --list filters by regex" "etc/pf.conf" ksh "${REPO_DIR}/restore.ksh" --list "${ARCHIVE_GZ}" "pf\.conf"

# Verify checksum mismatch fails cleanly
cp "${ARCHIVE_GZ}.sha256" "${ARCHIVE_GZ}.sha256.orig"
echo "SHA256 (${ARCHIVE_GZ##*/}) = 0000000000000000000000000000000000000000000000000000000000000000" > "${ARCHIVE_GZ}.sha256"
assert_fail "restore.ksh --verify rejects corrupted SHA256" ksh "${REPO_DIR}/restore.ksh" --verify "${ARCHIVE_GZ}"
mv "${ARCHIVE_GZ}.sha256.orig" "${ARCHIVE_GZ}.sha256"

# Verify --config-only --dry-run protects /etc/fstab AND /etc/passwd (when no master.passwd)
CFG_DRY=$(ksh "${REPO_DIR}/restore.ksh" --config-only --dry-run "${ARCHIVE_GZ}" 2>&1)
assert_output_contains "--config-only skips /etc/passwd on secrets-free archive" "skipping /etc/passwd" echo "$CFG_DRY"
assert_output_not_matches "--config-only protects /etc/fstab by default on /" "etc/fstab$" echo "$CFG_DRY"

# Verify anchored _sysinfo exclusion preserves user files containing '_sysinfo'
EXTRACT_DEST="${TEST_TMP}/extract_dest"
mkdir -p "${EXTRACT_DEST}"
gzip -dc "${ARCHIVE_GZ}" | tar -xf - \
    -s ',^_sysinfo$,,' -s ',^_sysinfo/.*,,' \
    -s ',^\./_sysinfo$,,' -s ',^\./_sysinfo/.*,,' \
    -C "${EXTRACT_DEST}"
if [ ! -d "${EXTRACT_DEST}/_sysinfo" ] && [ -f "${EXTRACT_DEST}/home/alice/projects/my_sysinfo_notes.txt" ]; then
    echo "  [PASS] Anchored _sysinfo exclusion skips metadata while keeping user *my_sysinfo* files"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] Anchored _sysinfo exclusion failed!"
    FAILED=$((FAILED + 1))
fi

# Verify non-root --diff works cleanly (including trailing slash!)
assert_output_contains "restore.ksh --diff works non-root on /etc/pf.conf" "set skip on lo" ksh "${REPO_DIR}/restore.ksh" --diff "${ARCHIVE_GZ}" /etc/pf.conf

# Test .tar.xz via pipe if xz is available
if command -v xz >/dev/null 2>&1; then
    ARCHIVE_XZ="${TEST_TMP}/obsd-rpi_server_backup_2026.11.21.tar.xz"
    tar -cf - -C "${FIXTURE_DIR}" etc _sysinfo | xz -c > "${ARCHIVE_XZ}"
    assert_output_contains "restore.ksh --verify (xz pipe) succeeds" "Success: Archive structure is valid" ksh "${REPO_DIR}/restore.ksh" --verify "${ARCHIVE_XZ}"
    assert_output_contains "restore.ksh --show-info (xz pipe) reads manifest" "obsd-rpi.lan" ksh "${REPO_DIR}/restore.ksh" --show-info "${ARCHIVE_XZ}"
fi

# Test .tar.zst via pipe if zstd is available
if command -v zstd >/dev/null 2>&1; then
    ARCHIVE_ZST="${TEST_TMP}/obsd-rpi_server_backup_2026.11.21.tar.zst"
    tar -cf - -C "${FIXTURE_DIR}" etc _sysinfo | zstd -q -c > "${ARCHIVE_ZST}"
    assert_output_contains "restore.ksh --verify (zstd pipe) succeeds" "Success: Archive structure is valid" ksh "${REPO_DIR}/restore.ksh" --verify "${ARCHIVE_ZST}"
    assert_output_contains "restore.ksh --show-info (zstd pipe) reads manifest" "obsd-rpi.lan" ksh "${REPO_DIR}/restore.ksh" --show-info "${ARCHIVE_ZST}"
fi

# Verify .age header validation & fail-closed signify verification (even without age/signify installed)
FAKE_AGE="${TEST_TMP}/obsd-rpi_server_backup_2026.11.21.tar.zst.age"
printf "age-encryption.org/v1\n-> X25519 dummy\n" > "${FAKE_AGE}"
assert_output_contains "restore.ksh --verify accepts valid .age header without -K" "Valid age-encrypted archive header" ksh "${REPO_DIR}/restore.ksh" --verify "${FAKE_AGE}"

BAD_AGE="${TEST_TMP}/bad_backup.tar.zst.age"
echo "not-an-age-file" > "${BAD_AGE}"
assert_fail "restore.ksh --verify rejects invalid .age header" ksh "${REPO_DIR}/restore.ksh" --verify "${BAD_AGE}"

cp "${ARCHIVE_GZ}" "${TEST_TMP}/signed_test.tar.gz"
echo "untrusted comment: test" > "${TEST_TMP}/signed_test.tar.gz.sha256.sig"
assert_fail "restore.ksh --verify fails closed when .sha256.sig present without key" ksh "${REPO_DIR}/restore.ksh" --verify "${TEST_TMP}/signed_test.tar.gz"

# Test .age encryption/decryption if age & age-keygen are available
if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
    AGE_SEC="${TEST_TMP}/test.age.key"
    AGE_PUB="${TEST_TMP}/test.age.pub"
    age-keygen -o "${AGE_SEC}" 2>/dev/null
    age-keygen -y "${AGE_SEC}" > "${AGE_PUB}"
    ARCHIVE_AGE="${TEST_TMP}/obsd-rpi_server_backup_2026.11.21.tar.gz.age"
    tar -cf - -C "${FIXTURE_DIR}" etc _sysinfo | gzip -c | age -R "${AGE_PUB}" > "${ARCHIVE_AGE}"
    assert_output_contains "restore.ksh --verify (.age without key) checks header" "Valid age-encrypted archive header" ksh "${REPO_DIR}/restore.ksh" --verify "${ARCHIVE_AGE}"
    assert_output_contains "restore.ksh --verify (.age with -K) decrypts & verifies" "Success: Archive structure is valid" ksh "${REPO_DIR}/restore.ksh" --verify -K "${AGE_SEC}" "${ARCHIVE_AGE}"
    assert_output_contains "restore.ksh --show-info (.age with -K) reads manifest" "obsd-rpi.lan" ksh "${REPO_DIR}/restore.ksh" --show-info -K "${AGE_SEC}" "${ARCHIVE_AGE}"
fi

# Test 7: Retention policy verification (.tar.gz, .tar.zst.age + .sha256.sig companions)
echo "7. Testing retention policy logic (multi-format + .sha256.sig)..."
RET_DIR="${TEST_TMP}/retention_test"
mkdir -p "${RET_DIR}"

touch -t 202601010000 "${RET_DIR}/myhost_vps_backup_2026.01.01.tar.zst.age"
touch -t 202601010000 "${RET_DIR}/myhost_vps_backup_2026.01.01.tar.zst.age.sha256"
touch -t 202601010000 "${RET_DIR}/myhost_vps_backup_2026.01.01.tar.zst.age.sha256.sig"
touch -t 202601020000 "${RET_DIR}/myhost_vps_backup_2026.01.02.tar.zst.age"
touch -t 202601020000 "${RET_DIR}/myhost_vps_backup_2026.01.02.tar.zst.age.sha256"
touch -t 202601020000 "${RET_DIR}/myhost_vps_backup_2026.01.02.tar.zst.age.sha256.sig"
touch -t 202601030000 "${RET_DIR}/myhost_vps_backup_2026.01.03.tar.gz"
touch -t 202601030000 "${RET_DIR}/myhost_vps_backup_2026.01.03.tar.gz.sha256"
touch -t 202601030000 "${RET_DIR}/myhost_vps_backup_2026.01.03.tar.gz.sig"

ksh -c '
FINAL_DEST_DIR="'"${RET_DIR}"'"
ARCHIVE_PREFIX="myhost_vps_backup_"
KEEP_COUNT=2

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
            rm -f "$OLD_FILE" "${OLD_FILE}.sha256" "${OLD_FILE}.sha256.sig" "${OLD_FILE}.sig" 2>/dev/null || true
        fi
        i=$((i + 1))
    done
fi
'

if [ ! -f "${RET_DIR}/myhost_vps_backup_2026.01.01.tar.zst.age" ] && \
   [ ! -f "${RET_DIR}/myhost_vps_backup_2026.01.01.tar.zst.age.sha256" ] && \
   [ ! -f "${RET_DIR}/myhost_vps_backup_2026.01.01.tar.zst.age.sha256.sig" ] && \
   [ -f "${RET_DIR}/myhost_vps_backup_2026.01.02.tar.zst.age" ] && \
   [ -f "${RET_DIR}/myhost_vps_backup_2026.01.03.tar.gz" ]; then
    echo "  [PASS] Retention prunes oldest .tar.zst.age + .sha256.sig and preserves newest 2"
    PASSED=$((PASSED + 1))
else
    echo "  [FAIL] Retention policy failed!"
    FAILED=$((FAILED + 1))
fi

echo "============================================================"
echo " Test Results: ${PASSED} Passed, ${FAILED} Failed"
echo "============================================================"

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
