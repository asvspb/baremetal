#!/usr/bin/env bash
# ==============================================================================
# tests/bats/scenarios/lib.sh — общая библиотека интеграционных сценариев (L3).
#
# Сценарий = обычный bash-скрипт: настраивает окружение/заглушки, подключает
# тестируемый скрипт через source (guard делает это безопасным), вызывает
# нужную функцию и печатает машиночитаемый результат на stdout.
# bats-тест запускает сценарий подпроцессом и проверяет вывод/код возврата.
#
# Использование в сценарии:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#   scenario_init deploy   # или usb
#   ... вызовы ...
# ==============================================================================
set -uo pipefail

SCEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCEN_DIR}/../../.." && pwd)"
SCEN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/deploy-test-XXXXXX")"

# Универсальные заглушки: exit 0 + запись вызова в $STUB_LOG/<cmd>.log
SCEN_GENERIC_STUBS=(parted mkfs.fat mkfs.ntfs mkfs.exfat mkfs.vfat mkfs.ext4
    mkfs.f2fs mkswap partprobe e2fsck resize2fs sleep fallocate
    swapoff swapon blkid dosfsck)

scenario_cleanup() {
    rm -rf "$SCEN_TMP"
}

scenario_init() {
    local mode="${1:-deploy}"
    STUB_LOG="${SCEN_TMP}/stublog"
    STUB_BIN="${SCEN_TMP}/bin"
    mkdir -p "$STUB_LOG" "$STUB_BIN"
    cp "${REPO_DIR}/tests/stubs/custom/"* "$STUB_BIN/" 2>/dev/null
    chmod +x "$STUB_BIN/"*
    local cmd
    for cmd in "${SCEN_GENERIC_STUBS[@]}"; do
        STUB_BIN="$STUB_BIN" bash "${REPO_DIR}/tests/stubs/make-stub.sh" "$cmd" 0
    done
    # dd — запрещённая заглушка: всегда сбой (TEST-SPEC §6)
    STUB_BIN="$STUB_BIN" bash "${REPO_DIR}/tests/stubs/make-stub.sh" dd 1
    case "$mode" in
        deploy)
            # deploy-сценарии не нуждаются в реальных mkdir/chmod/chown
            for cmd in mkdir chmod chown; do
                STUB_BIN="$STUB_BIN" bash "${REPO_DIR}/tests/stubs/make-stub.sh" "$cmd" 0
            done
            ;;
        usb) : ;;  # usb-сценариям нужны РЕАЛЬНЫЕ mkdir/cp в tmp-каталогах
    esac
    export PATH="${STUB_BIN}:${PATH}"
    export STUB_LOG
}

# Провал сценария, если мутирующая команда вызывалась (безопасность L3)
scenario_assert_no_mutating() {
    local cmd
    for cmd in parted mkfs.fat mkfs.ntfs mkfs.exfat mkfs.vfat mkfs.ext4 mkswap dd sfdisk; do
        if [[ -f "$STUB_LOG/$cmd.log" ]]; then
            echo "SAFETY-FAIL: мутирующая команда '$cmd' вызвана: $(head -n 2 "$STUB_LOG/$cmd.log")"
            return 1
        fi
    done
}

# Запустить функцию в подкожной оболочке, поймать rc и весь вывод
scenario_capture() {
    local out rc
    out=$("$@" 2>&1)
    rc=$?
    printf 'RC=%s\n' "$rc"
    printf '%s\n' "$out"
}
