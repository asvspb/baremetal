#!/usr/bin/env bash
# I-M5: успешный цикл: бэкап-фикстура -> разметка (стаб Ventoy) -> восстановление
# -> сверка -> бэкап удалён. DATA_FS=none: единственный раздел P1 (fake-диск).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scenario_init usb
# shellcheck disable=SC1091
source "${REPO_DIR}/make-boot-usb.sh" >/dev/null 2>&1
export STUB_DF_TYPE="ext4"
export STUB_UMOUNT_SAVE="${SCEN_TMP}/saved"
TARGET_DISK="/dev/fakedisk"
DATA_FS="none"
TOTAL_GIB=31; TOTAL_MIB=31744; TOTAL_BYTES=33285994496
VENTOY_SIZE_G=8
LABEL_P1="FD-0"
LABEL_P3=""
P1="/dev/fakedisk1"; P3="/dev/fakedisk3"
DO_RESTORE=1
BACKUP_DIR="${SCEN_TMP}/backup"
/bin/mkdir -p "$BACKUP_DIR/iso" "$BACKUP_DIR/data/sub"
printf 'ISO-CONTENT' > "$BACKUP_DIR/iso/image.iso"
printf 'hello' > "$BACKUP_DIR/data/file.txt"
printf 'nested' > "$BACKUP_DIR/data/sub/nested.txt"
# закреплённый стаб Ventoy2Disk.sh в VENTOY_DIR теста
VENTOY_DIR="${SCEN_TMP}/ventoy"
/bin/mkdir -p "$VENTOY_DIR"
cat > "$VENTOY_DIR/Ventoy2Disk.sh" <<VSTUB
#!/usr/bin/env bash
if [[ -n "\${STUB_LOG:-}" && -d "\${STUB_LOG:-}" ]]; then
    printf '%s\n' "Ventoy2Disk.sh \$* [cwd=\$PWD]" >> "\$STUB_LOG/Ventoy2Disk.log"
fi
exit 0
VSTUB
chmod +x "$VENTOY_DIR/Ventoy2Disk.sh"
rc=0
out=$(printf 'ДА\nn\n' | execute_partitioning 2>&1) || rc=$?
printf '%s\n' "$out" > "${SCEN_TMP}/execute_partitioning.out"
echo "RC=$rc"
# 1) разметка выполнялась: parted и Ventoy2Disk вызывались
[[ -f "$STUB_LOG/parted.log" ]] && echo "PARTED-CALLED"
[[ -f "$STUB_LOG/Ventoy2Disk.log" ]] && echo "VENTOY-CALLED"
# 2) файлы восстановлены в точки монтирования (mount-стаб -> реальные tmp-каталоги)
mnt1="${SCEN_TMP}/saved/mnt_res_p1_$$"; mntd="${SCEN_TMP}/saved/mnt_res_pd_$$"
[[ -f "$mnt1/image.iso" ]] && echo "ISO-RESTORED"
[[ -f "$mntd/file.txt" && "$(cat "$mntd/file.txt" 2>/dev/null)" == "hello" ]] && echo "DATA-RESTORED"
[[ -f "$mntd/sub/nested.txt" ]] && echo "NESTED-RESTORED"
# 3) бэкап удалён только после успешной сверки
[[ ! -d "$BACKUP_DIR" ]] && echo "BACKUP-DELETED"
rm -rf "/tmp/mnt_ventoy_$$"
scenario_cleanup
