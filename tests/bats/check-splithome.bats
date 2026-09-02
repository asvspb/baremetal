#!/usr/bin/env bats
load 'helpers'

# ==============================================================================
# L3/L5: split-home.sh — подпроцесс (файл по правилам задачи НЕ редактируется).
# S-H1 требует root (die по EUID стоит раньше проверки Live-среды) — вне root SKIP.
# ==============================================================================

@test "S-H2: --help -> exit 0 и заголовок" {
    run timeout 60 bash "${REPO_DIR}/split-home.sh" --help
    assert_success
    assert_output --partial "split-home.sh — Автоматическое"
}

@test "S-H1: не-Live система без --dry-run -> die «Загрузитесь с Live-USB»" {
    [[ $EUID -eq 0 ]] || skip "нужен root: die о Live-среде стоит после EUID-проверки"
    run timeout 60 bash "${REPO_DIR}/split-home.sh"
    assert_failure
    assert_output --partial "Загрузитесь с Live-USB"
}

@test "S-H1: без root -> die про права (безопасное поведение сохранено)" {
    [[ $EUID -eq 0 ]] && skip "уже root"
    run timeout 60 bash "${REPO_DIR}/split-home.sh"
    assert_failure
    assert_output --partial "Скрипт требует прав root"
}
