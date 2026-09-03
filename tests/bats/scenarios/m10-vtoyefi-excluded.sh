#!/usr/bin/env bash
# I-M10 (регрессия 2026-09-02): служебный раздел Ventoy (VTOYEFI, PARTLABEL +
# GPT-тип ESP) не должен попадать в бэкап пользовательских данных — раньше
# восстановление выгружало его файлы (EFI/, grub/, tool/, ENROLL_*.cer) на
# раздел данных. Диск из трёх разделов; mount для VTOYEFI настроен на сбой:
# попытка забэкапить его завершает скрипт с ошибкой (die), после фикса раздел
# вообще не открывается.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scenario_init usb
# shellcheck disable=SC1091
source "${REPO_DIR}/make-boot-usb.sh" >/dev/null 2>&1
export STUB_DF_TYPE="ext4"
export STUB_DU_BYTES="8000000"
STUB_LSBLK_PART_INFO="$(printf '/dev/fakedisk1 Ventoy ebd0a0a2-b9e5-4433-87c0-68b6b72699c7\n/dev/fakedisk2 VTOYEFI c12a7328-f81f-11d2-ba4b-00a0c93ec93b\n/dev/fakedisk3 DATA ebd0a0a2-b9e5-4433-87c0-68b6b72699c7')"
export STUB_LSBLK_PART_INFO
export STUB_MOUNT_FAIL_PARTS="/dev/fakedisk2"
TARGET_DISK="/dev/fakedisk"
DO_RESTORE=0

# «пользовательские данные» на разделах 1/3
fill="${SCEN_TMP}/fill"
/bin/mkdir -p "$fill"
printf 'doc' > "$fill/doc.txt"
export STUB_MOUNT_FILL="$fill"

rc=0
out=$(printf 'Y\n' | backup_existing_files 2>&1) || rc=$?
echo "RC=$rc"
echo "$out"

bak="/tmp/usb_backup_$$"
if [[ -d "$bak/data" && -f "$bak/data/doc.txt" ]]; then echo "DATA-BACKED-UP"; else echo "DATA-MISSED"; fi
if [[ -e "$bak/data/grub" || -e "$bak/data/EFI" || -e "$bak/data/tool" || -e "$bak/data/ENROLL_THIS_KEY_IN_MOKMANAGER.cer" ]]; then
    echo "VTOY-JUNK-IN-BACKUP"
else
    echo "NO-VTOY-JUNK"
fi
if grep -q '/dev/fakedisk2' "$STUB_LOG/mount.log" 2>/dev/null; then
    echo "VTOYEFI-MOUNTED"
else
    echo "VTOYEFI-SKIPPED"
fi
rm -rf "$bak"
scenario_cleanup
exit "$rc"
