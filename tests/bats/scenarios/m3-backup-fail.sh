#!/usr/bin/env bash
# I-M3 (критический): сбой копирования на бэкапе -> die, флешка НЕ тронута.
# Вариант rsync-fail или cp-fail (ISO-копирование).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scenario_init usb
# shellcheck disable=SC1091
source "${REPO_DIR}/make-boot-usb.sh" >/dev/null 2>&1
export STUB_DF_TYPE="ext4"
export STUB_DU_BYTES="8000000"
export STUB_LSBLK_PARTS_FULL="$(printf '/dev/fakedisk1\n/dev/fakedisk3')"
TARGET_DISK="/dev/fakedisk"
DO_RESTORE=0
partition_fill="${SCEN_TMP}/partdata"
/bin/mkdir -p "$partition_fill"
printf 'ISO-CONTENT' > "$partition_fill/fake.iso"
printf 'doc' > "$partition_fill/doc.txt"
export STUB_MOUNT_FILL="$partition_fill"
case "${1:-rsync-fail}" in
    rsync-fail) export STUB_RSYNC_FAIL="1" ;;
    cp-fail)    export STUB_CP_FAIL="1" ;;
esac
rc=0
out=$(printf 'Y\n' | backup_existing_files 2>&1) || rc=$?
echo "RC=$rc"
echo "$out"
# Бэкап сохранен: каталог выбирается в подкожной оболочке, но путь
# детерминирован (df -T -> ext4 => /tmp/usb_backup_$$)
if [[ -d "/tmp/usb_backup_$$" ]]; then echo "BACKUP-KEPT"; else echo "BACKUP-GONE"; fi
# Флешка НЕ тронута: ни одной мутирующей команды (в т.ч. parted/mkfs/dd)
if scenario_assert_no_mutating; then echo "USB-UNTOUCHED"; else echo "USB-TOUCHED"; fi
scenario_cleanup
exit "$rc"
