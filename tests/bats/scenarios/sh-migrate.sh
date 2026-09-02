#!/usr/bin/env bash
# S5: критические пути do_migrate_home из split-home.sh.
# Целевые «устройства» — несуществующие /dev/fakep7, /dev/fakep8: работают
# только заглушки mount/umount/blkid, реальные диски не затрагиваются.
#
# ВАЖНО: do_migrate_home вызывается в ДОЧЕРНЕМ bash (без ||-контекста!).
# `out=$(f) || rc=$?` подавил бы errexit внутри подстановки, и голый сбой
# rsync (у него нет die, работает set -e) не остановил бы функцию.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scenario_init usb

# blkid-заглушка с фиксированным UUID для P8 (do_migrate_home читает его в fstab)
STUB_BIN="$STUB_BIN" bash "${REPO_DIR}/tests/stubs/make-stub.sh" blkid 0 --stdout "aaaa-bbbb-cccc"

variant="${1:-success}"
case "$variant" in
    verify-fail) export STUB_RSYNC_DIFF=1 ;;   # -n проход увидит расхождение
    rsync-fail)  export STUB_RSYNC_FAIL=1 ;;   # копирующий проход падает
    success)     : ;;                          # реальные rsync оба прохода
    *) echo "RC=2"; echo "unknown variant"; exit 2 ;;
esac

# фикстура: «корень p7» с /home и /etc/fstab, пустой «p8»
MNT_ROOT="/tmp/split_root_mnt"
MNT_HOME="/tmp/split_home_mnt"
# leftover'ы прошлого root-прогона может убрать только root — чистим с fallback
rm -rf "$MNT_ROOT" "$MNT_HOME" 2>/dev/null \
    || sudo -n rm -rf "$MNT_ROOT" "$MNT_HOME" 2>/dev/null || true
/bin/mkdir -p "$MNT_ROOT/home/user/docs" "$MNT_ROOT/etc" "$MNT_ROOT/root" "$MNT_HOME"
printf 'important data\n' > "$MNT_ROOT/home/user/docs/file.txt"
printf 'nested\n' > "$MNT_ROOT/home/user/docs/nested.txt"
printf 'UUID=root-fs  /  ext4  defaults  0  1\n' > "$MNT_ROOT/etc/fstab"
printf 'parttable-stub\n' > "/tmp/parttable-before-split-test-ts.bak"

# дочерний bash: set -e активен, как в реальном запуске main()
out=$(bash -c "
    set -Eeuo pipefail
    source '${REPO_DIR}/split-home.sh' >/dev/null 2>&1
    DRY=0
    TS='test-ts'
    P7='/dev/fakep7'
    P8='/dev/fakep8'
    do_migrate_home
" 2>&1)
rc=$?
echo "RC=$rc"
echo "$out"

# состояние старого /home
if [[ -f "$MNT_ROOT/home/user/docs/file.txt" ]]; then
    echo "HOME-INTACT"
else
    echo "HOME-DELETED"
fi
# fstab
if grep -q '^UUID=aaaa-bbbb-cccc .* /home' "$MNT_ROOT/etc/fstab" 2>/dev/null; then
    echo "FSTAB-HAS-P8"
else
    echo "FSTAB-WITHOUT-P8"
fi
[[ -f "$MNT_ROOT/etc/fstab.bak-test-ts" ]] && echo "FSTAB-BAK-EXISTS"
[[ -f "$MNT_ROOT/root/parttable-before-split-test-ts.bak" ]] && echo "PARTTABLE-COPIED"
[[ -d "$MNT_ROOT/home" ]] && [[ -z "$(ls -A "$MNT_ROOT/home" 2>/dev/null)" ]] && echo "HOME-EMPTY"

rm -rf "$MNT_ROOT" "$MNT_HOME" "/tmp/parttable-before-split-test-ts.bak" 2>/dev/null \
    || sudo -n rm -rf "$MNT_ROOT" "$MNT_HOME" "/tmp/parttable-before-split-test-ts.bak" 2>/dev/null || true
scenario_cleanup
exit "$rc"
