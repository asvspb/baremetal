#!/usr/bin/env bash
# A9: release_nvme_mounts — авто-отмонтирование автомонтированных Live-средой
# nvme-разделов ДО preflight-монтирования p7 (повторное ro-монтирование уже
# смонтированной rw ФС падало с EBUSY, 2026-09-04).
# Фейковый PROC_MOUNTS + своя заглушка umount; реальные диски не затрагиваются.
#
# Варианты: ok — обе nvme-точки отмонтированы, rc 0; busy — umount падает
# (точка занята файловым менеджером) -> die ДО любых изменений диска.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scenario_init usb

variant="${1:-ok}"
FAKE_MOUNTS="$SCEN_TMP/mounts"
{
    echo "overlay / overlay rw,relatime 0 0"
    echo "/dev/nvme0n1p7 /run/media/ubuntu/1b8e3e50-2e22-4088-a3a5-396293780ff2 ext4 rw,nosuid,nodev,relatime 0 0"
    echo "/dev/nvme0n1p8 /run/media/ubuntu/Distr exfat rw,relatime 0 0"
    echo "tmpfs /tmp tmpfs rw 0 0"
} > "$FAKE_MOUNTS"

# своя заглушка umount: лог вызова; при успехе убирает строку точки из
# фейкового PROC_MOUNTS (симуляция ядра); STUB_UMOUNT_FAIL=1 -> сбой
cat > "$STUB_BIN/umount" <<'EOF'
#!/usr/bin/env bash
echo "umount $*" >> "${STUB_LOG:?}/umount.log"
[[ "${STUB_UMOUNT_FAIL:-0}" == "1" ]] && exit 1
tgt="${*: -1}"
if [[ -n "${FAKE_MOUNTS:-}" && -f "$FAKE_MOUNTS" ]]; then
    grep -vF " $tgt " "$FAKE_MOUNTS" > "$FAKE_MOUNTS.tmp" && mv "$FAKE_MOUNTS.tmp" "$FAKE_MOUNTS"
fi
exit 0
EOF
chmod +x "$STUB_BIN/umount"
export FAKE_MOUNTS

case "$variant" in
    ok)   : ;;
    busy) export STUB_UMOUNT_FAIL=1 ;;
    *) echo "RC=2"; echo "unknown variant"; exit 2 ;;
esac

out=$(bash -c "
    set -Eeuo pipefail
    source '${REPO_DIR}/split-home.sh' >/dev/null 2>&1
    DRY=0
    PROC_MOUNTS='${FAKE_MOUNTS}'
    release_nvme_mounts
    echo 'RELEASE-OK'
" 2>&1)
rc=$?
echo "RC=$rc"
echo "$out"
[[ -f "$STUB_LOG/umount.log" ]] && cat "$STUB_LOG/umount.log"
scenario_assert_no_mutating >/dev/null 2>&1 && echo "NO-MUTATING"

scenario_cleanup
exit "$rc"
