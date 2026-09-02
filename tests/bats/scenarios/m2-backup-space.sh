#!/usr/bin/env bash
# I-M2: check_backup_space — мало места -> die ДО копирования; достаточно -> 0
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scenario_init usb
# shellcheck disable=SC1091
source "${REPO_DIR}/make-boot-usb.sh" >/dev/null 2>&1
export STUB_DF_TYPE="ext4"
BACKUP_DIR="${SCEN_TMP}/bak"
/bin/mkdir -p "$BACKUP_DIR"
variant="$1"
case "$variant" in
    little)
        export STUB_DF_AVAIL_KB="100"
        rc=0; out=$(check_backup_space 10000000 2>&1) || rc=$?
        echo "RC=$rc"; echo "$out"
        # бэкап ещё не начался: мутирующих вызовов нет
        scenario_assert_no_mutating >/dev/null 2>&1 && echo "NO-MUTATIONS"
        exit "$rc" ;;
    enough)
        export STUB_DF_AVAIL_KB="999999999"
        rc=0; out=$(check_backup_space 10000000 2>&1) || rc=$?
        echo "RC=$rc"; echo "$out" ;;
    *) echo "RC=2" ;;
esac
scenario_cleanup
