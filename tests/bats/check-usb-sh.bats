#!/usr/bin/env bats
load 'helpers'

# ==============================================================================
# L2/L3: make-boot-usb.sh — юниты (U-M1) и интеграция на заглушках (T3).
# Source безопасен: main под guard; заглушки в PATH отключают установку
# пакетов на верхнем уровне (command -v находит стабы).
# ==============================================================================

# source make-boot-usb.sh в изолированном bash с заглушками; доп. код — аргументом
usb_run() {
    local extra="$1"
    bash -c "
        set -uo pipefail
        STUB_LOG=\"\$(mktemp -d)\"
        export STUB_LOG
        PATH=\"${REPO_DIR}/tests/stubs/custom:${PATH}\"
        source '${REPO_DIR}/make-boot-usb.sh' >/dev/null 2>&1
        ${extra}
    "
}

@test "U-M1: verify_restored_tree — полное совпадение -> rc 0" {
    local bak dest
    bak="$(mktemp -d)"; dest="$(mktemp -d)"
    printf 'hello world' > "$bak/a.txt"
    mkdir -p "$bak/sub" && printf 'nested' > "$bak/sub/n.txt"
    cp -a "$bak/." "$dest/"
    run usb_run "verify_restored_tree '$bak' '$dest'"
    assert_success
    assert_output --partial "Сверка восстановления пройдена"
    rm -rf "$bak" "$dest"
}

@test "U-M1: verify_restored_tree — размер файла отличается -> rc 1" {
    local bak dest
    bak="$(mktemp -d)"; dest="$(mktemp -d)"
    printf 'hello world' > "$bak/a.txt"
    printf 'hello' > "$dest/a.txt"
    run usb_run "verify_restored_tree '$bak' '$dest'"
    assert_failure
    assert_output --partial "Сверка восстановления НЕ пройдена"
    rm -rf "$bak" "$dest"
}

@test "U-M1: verify_restored_tree — файл отсутствует на флешке -> rc 1" {
    local bak dest
    bak="$(mktemp -d)"; dest="$(mktemp -d)"
    printf 'hello world' > "$bak/a.txt"
    run usb_run "verify_restored_tree '$bak' '$dest'"
    assert_failure
    assert_output --partial "не найден файл"
    rm -rf "$bak" "$dest"
}
