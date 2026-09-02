#!/usr/bin/env bash
# ==============================================================================
# tests/bats/helpers.bash — общие помощники для bats-наборов проекта
#
# Загружается из .bats-файлов через:  load 'helpers'
# Предоставляет: setup_stub_env / teardown_stub_env, stub_called,
# assert_no_mutating_calls, fixture-функции.
# ==============================================================================

REPO_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

# библиотеки bats (устанавливаются tests/setup.sh)
# shellcheck source=/dev/null
source "${REPO_DIR}/tests/.deps/bats-support/load.bash"
# shellcheck source=/dev/null
source "${REPO_DIR}/tests/.deps/bats-assert/load.bash"

# Критичные «мутирующие» команды: их вызовы в L3-тестах запрещены
MUTATING_CMDS=(parted mkfs.fat mkfs.ntfs mkfs.exfat mkfs.vfat mkfs.ext4 mkswap dd sfdisk)

setup_stub_env() {
    STUB_LOG="${BATS_TEST_TMPDIR}/stublog"
    STUB_BIN="${BATS_TEST_TMPDIR}/stubbin"
    mkdir -p "$STUB_LOG" "$STUB_BIN"

    # кастомные заглушки (lsblk, df, cp, rsync, dd, ...)
    cp "${REPO_DIR}/tests/stubs/custom/"* "$STUB_BIN/"
    chmod +x "$STUB_BIN/"*

    # универсальные заглушки: exit 0 + запись в лог
    local cmd
    for cmd in parted mkfs.fat mkfs.ntfs mkfs.exfat mkfs.vfat mkfs.ext4 \
               mkswap partprobe e2fsck resize2fs sleep fallocate \
               mount umount swapoff swapon blkid; do
        STUB_BIN="$STUB_BIN" bash "${REPO_DIR}/tests/stubs/make-stub.sh" "$cmd" 0
    done

    # заглушка dd ОБЯЗАТЕЛЬНО с ошибкой (защита от случайного запуска)
    STUB_BIN="$STUB_BIN" bash "${REPO_DIR}/tests/stubs/make-stub.sh" dd 1

    export PATH="${STUB_BIN}:${PATH}"
    export STUB_LOG
}

teardown_stub_env() {
    # вернуть PATH и убрать временные каталоги (bats удалит BATS_TEST_TMPDIR сам)
    if [[ -n "${STUB_BIN:-}" ]]; then
        PATH="${PATH#"$STUB_BIN:"}"
        unset STUB_BIN
    fi
    unset STUB_LOG || true
}

# Истина, если заглушка <cmd> вызывалась хотя бы раз
stub_called() {
    [[ -f "$STUB_LOG/$1.log" ]]
}

# Провал теста, если любая мутирующая команда вызывалась
assert_no_mutating_calls() {
    local cmd
    for cmd in "${MUTATING_CMDS[@]}"; do
        if [[ -f "$STUB_LOG/$cmd.log" ]]; then
            bats::fail "мутирующая команда '$cmd' была вызвана в L3-тесте: $(cat "$STUB_LOG/$cmd.log" | head -n 3)"
        fi
    done
}

# Каталог фикстур с «ISO-пустышками» (имена важнее содержимого — find_isos
# ищет по маске; *.iso в /tmp ломать golden не должны — файлы живут
# в BATS_TEST_TMPDIR и удаляются bats после теста)
make_iso_fixtures() {
    local dir="$1"
    mkdir -p "$dir"
    truncate -s 1M "$dir/fake-win.iso"
    truncate -s 1M "$dir/fake-ubuntu.iso"
}

# Подготовить tmp-каталог с мини-деревом бэкапа (iso + data)
make_backup_fixture() {
    local dir="$1"
    mkdir -p "$dir/iso" "$dir/data/sub"
    printf 'ISO-CONTENT' > "$dir/iso/image.iso"
    printf 'hello world' > "$dir/data/file.txt"
    printf 'nested' > "$dir/data/sub/nested.txt"
}
