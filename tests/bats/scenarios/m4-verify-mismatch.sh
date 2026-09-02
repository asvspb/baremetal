#!/usr/bin/env bash
# I-M4 (критический): сверка восстановления не сошлась -> бэкап НЕ удалён.
# Вариант iso: не хватает ISO; вариант data: не хватает данных.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scenario_init usb
# shellcheck disable=SC1091
source "${REPO_DIR}/make-boot-usb.sh" >/dev/null 2>&1
export STUB_DF_TYPE="ext4"
export STUB_CP_NOTHING="1"   # cp завершается успешно, НИЧЕГО не копируя
TARGET_DISK="/dev/fakedisk"
DATA_FS="none"
P1="/dev/fakedisk1"
P3="/dev/fakedisk3"
LABEL_P1="FD-0"
LABEL_P3=""
DO_RESTORE=1
BACKUP_DIR="${SCEN_TMP}/backup"
variant="${1:-iso}"
/bin/mkdir -p "$BACKUP_DIR/iso" "$BACKUP_DIR/data"
if [[ "$variant" == "iso" ]]; then
    printf 'ISO-CONTENT' > "$BACKUP_DIR/iso/image.iso"
else
    printf 'hello' > "$BACKUP_DIR/data/file.txt"
fi
rc=0
out=$(restore_files 2>&1) || rc=$?
echo "RC=$rc"
echo "$out"
if [[ -d "$BACKUP_DIR" ]]; then echo "BACKUP-KEPT"; else echo "BACKUP-GONE"; fi
scenario_cleanup
exit "$rc"
