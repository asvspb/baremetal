#!/usr/bin/env bash
# I-M1: choose_backup_dir — tmpfs -> /var/tmp (или введённый путь); ext4 -> /tmp
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scenario_init usb
# shellcheck disable=SC1091
source "${REPO_DIR}/make-boot-usb.sh" >/dev/null 2>&1
variant="$1"
case "$variant" in
    tmpfs-default)
        export STUB_DF_TYPE="tmpfs"
        out=$(printf '\n' | { choose_backup_dir 2>&1; echo "RESULT_DIR=$BACKUP_DIR"; }) || true
        echo "$out" | grep -E '^RESULT_DIR=' | head -n 1
        echo "$out" | grep -q '^RESULT_DIR=/var/tmp/usb_backup_' && echo "OK"
        rm -rf "$(echo "$out" | sed -n 's/^RESULT_DIR=//p' | head -n 1)" ;;
    tmpfs-custom)
        export STUB_DF_TYPE="tmpfs"
        custom="${SCEN_TMP}/custombak"
        out=$(printf '%s\n' "$custom" | { choose_backup_dir 2>&1; echo "RESULT_DIR=$BACKUP_DIR"; }) || true
        echo "$out" | grep -E '^RESULT_DIR=' | head -n 1
        echo "$out" | grep -q "^RESULT_DIR=$custom\$" && echo "OK"
        rm -rf "$custom" ;;
    ext4-default)
        export STUB_DF_TYPE="ext4"
        out=$(printf '\n' | { choose_backup_dir 2>&1; echo "RESULT_DIR=$BACKUP_DIR"; }) || true
        echo "$out" | grep -E '^RESULT_DIR=' | head -n 1
        echo "$out" | grep -q '^RESULT_DIR=/tmp/usb_backup_' && echo "OK"
        rm -rf "$(echo "$out" | sed -n 's/^RESULT_DIR=//p' | head -n 1)" ;;
    *) echo "RC=2" ;;
esac
scenario_cleanup
