#!/usr/bin/env bash
# A4: охрана разметки check_partition_layout из split-home.sh.
# Фейковый sysfs-каталог (PART_SYS_ROOT) с файлами start/size и blkid-заглушка
# с ответами по флагам (TYPE/PARTUUID) — реальные диски/parted не затрагиваются.
#
# Варианты (аргумент $1):
#   all-good        — отпечатки сходятся, функция возвращает 0
#   p9-exists       — в sysroot появился nvme0n1p9 -> die «уже выполнялась»
#   p8-missing      — нет nvme0n1p8 -> die «нет раздела Distr»
#   p8-fingerprint  — blkid возвращает не-exfat (STUB_D8_TYPE=vfat) -> die
#   p7-size         — size p7 не совпадает с отпечатком -> die
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scenario_init usb

variant="${1:-all-good}"
SYSROOT="$SCEN_TMP/sysroot"
mkdir -p "$SYSROOT/nvme0n1p7" "$SYSROOT/nvme0n1p8"
printf '638709760\n'   > "$SYSROOT/nvme0n1p7/start"
printf '1107075072\n'  > "$SYSROOT/nvme0n1p7/size"
printf '1745784832\n'  > "$SYSROOT/nvme0n1p8/start"

case "$variant" in
    p9-exists)      mkdir "$SYSROOT/nvme0n1p9" ;;
    p8-missing)     rm -rf "$SYSROOT/nvme0n1p8" ;;
    p8-fingerprint) export STUB_D8_TYPE="vfat" ;;
    p7-size)        printf '123456789\n' > "$SYSROOT/nvme0n1p7/size" ;;
    all-good)       : ;;
    *) echo "RC=2"; echo "unknown variant"; exit 2 ;;
esac

# blkid-заглушка: ответ зависит от запрошенного атрибута (-s TYPE/-s PARTUUID)
cat > "$STUB_BIN/blkid" <<'EOF'
#!/usr/bin/env bash
# управление: STUB_D8_TYPE, STUB_D8_PARTUUID
case "$*" in
    *"-s TYPE"*)     printf '%s\n' "${STUB_D8_TYPE:-exfat}" ;;
    *"-s PARTUUID"*) printf '%s\n' "${STUB_D8_PARTUUID:-58c56411-3703-410a-bda7-41278b287bca}" ;;
    *)               : ;;
esac
exit 0
EOF
chmod +x "$STUB_BIN/blkid"

# дочерний bash: set -e активен (после source), как в реальном запуске main()
out=$(bash -c "
    source '${REPO_DIR}/split-home.sh' >/dev/null 2>&1
    PART_SYS_ROOT='$SYSROOT'
    P7='/dev/fakep7'
    P8_DISTR='/dev/fakep8'
    P9='/dev/fakep9'
    check_partition_layout
    echo 'LAYOUT-OK'
" 2>&1)
rc=$?
echo "RC=$rc"
echo "$out"
# охрана не должна вызывать мутирующие parted/mkfs
if [[ ! -f "$STUB_LOG/parted.log" && ! -f "$STUB_LOG/mkfs.ext4.log" ]]; then
    echo "NO-MUTATING"
fi

scenario_cleanup
exit "$rc"
