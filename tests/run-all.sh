#!/usr/bin/env bash
# ==============================================================================
# run-all.sh <level> — единая точка запуска тестов (TEST-SPEC §8)
#
# Уровни:
#   fast   — L0 статика (check-files + shellcheck) + L2/L3 bats (без root)
#   ps     — L1 парсинг ps1 через pwsh (без pwsh = SKIP, не провал)
#   full   — fast + ps + L5 dry-run E2E (нужен root; без root L5 = SKIP)
#   loop   — L4 на loop-устройствах (нужен root + /dev/loop-control)
#
# Код возврата: 0 только если не было провалов (SKIP допустим).
# Каждый bats-файл обёрнут в timeout: зависший read = провал (§12).
# ==============================================================================
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
BATS="${TESTS_DIR}/.deps/bats-core/bin/bats"

level="${1:-fast}"
declare -i failures=0

C_YEL="\033[1;33m"; C_GRN="\033[1;32m"; C_RED="\033[1;31m"; C_BLU="\033[1;34m"; C_RST="\033[0m"
info()  { echo -e "${C_BLU}[run-all]${C_RST} $*"; }
ok()    { echo -e "${C_GRN}[OK]${C_RST} $*"; }
fail_() { echo -e "${C_RED}[ПРОВАЛ]${C_RST} $*"; }
warn_() { echo -e "${C_YEL}[ВНИМАНИЕ]${C_RST} $*"; }

run_bats() {
    local file="$1" tmo="${2:-180}"
    local name
    name="$(basename "$file")"
    info "bats: ${name} (timeout ${tmo}s)"
    if ! timeout "$tmo" "$BATS" --print-output-on-failure "${TESTS_DIR}/bats/${file}"; then
        failures+=1
        fail_ "${name} завершился с провалами/таймаутом"
    else
        ok "${name}"
    fi
}

run_static() {
    info "L0: check-files.sh (BOM/CRLF/структура ps1, bash -n)"
    if bash "${REPO_DIR}/check-files.sh" >/dev/null; then
        ok "check-files.sh"
    else
        bash "${REPO_DIR}/check-files.sh"; failures+=1
    fi

    info "L0: shellcheck -S warning по всем .sh"
    local sc_out
    sc_out=$(shellcheck -S warning \
        "${REPO_DIR}/deploy.sh" \
        "${REPO_DIR}/make-boot-usb.sh" \
        "${REPO_DIR}/split-home.sh" \
        "${REPO_DIR}/check-files.sh" \
        "${TESTS_DIR}/setup.sh" \
        "${TESTS_DIR}/run-all.sh" \
        "${TESTS_DIR}/stubs/make-stub.sh" \
        "${TESTS_DIR}/stubs/custom/"* 2>&1)
    if [[ $? -eq 0 ]]; then
        ok "shellcheck: 0 замечаний"
    else
        echo "$sc_out" >&2
        failures+=1
    fi
}

case "$level" in
    fast)
        if [[ ! -x "$BATS" ]]; then
            fail_ "bats не найден ($BATS). Запустите: bash tests/setup.sh"
            exit 1
        fi
        run_static
        run_bats meta.bats 60
        run_bats check-deploy.bats 180
        run_bats check-usb-sh.bats 180
        run_bats check-splithome.bats 60
        ;;
    ps)
        if [[ ! -x "$BATS" ]]; then
            fail_ "bats не найден ($BATS). Запустите: bash tests/setup.sh"
            exit 1
        fi
        run_bats ps-parse.bats 300
        ;;
    loop)
        if [[ ! -x "$BATS" ]]; then
            fail_ "bats не найден ($BATS). Запустите: bash tests/setup.sh"
            exit 1
        fi
        warn_ "L4 выполняет реальные parted/mkfs на loop-устройствах (/dev/loop*)"
        run_bats loop-integration.bats 900
        ;;
    full)
        if [[ ! -x "$BATS" ]]; then
            fail_ "bats не найден ($BATS). Запустите: bash tests/setup.sh"
            exit 1
        fi
        run_static
        run_bats meta.bats 60
        run_bats check-deploy.bats 180
        run_bats check-usb-sh.bats 180
        run_bats check-splithome.bats 60
        run_bats ps-parse.bats 300
        run_bats dryrun-e2e.bats 600
        ;;
    *)
        echo "usage: run-all.sh [fast|ps|loop|full]" >&2
        exit 2
        ;;
esac

echo
echo -e "${C_BLU}=============== СВОДКА (${level}) ===============${C_RST}"
if (( failures > 0 )); then
    fail_ "провалов: ${failures}"
    exit 1
fi
ok "все тесты уровня ${level} прошли (SKIP допустим)"
exit 0
