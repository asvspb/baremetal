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

# ---------- S5: критические пути do_migrate_home (сценарии sh-migrate.sh) ----------

@test "S5 КРИТИЧЕСКИЙ: сбой сверки -> die, старый /home цел, fstab без /home" {
    run timeout 60 bash "${REPO_DIR}/tests/bats/scenarios/sh-migrate.sh" verify-fail
    assert_failure
    assert_output --partial "RC=1"
    assert_output --partial "Сверка /home после копирования не сошлась"
    assert_output --partial "HOME-INTACT"
    assert_output --partial "FSTAB-WITHOUT-P8"
    refute_output --partial "FSTAB-HAS-P8"
    refute_output --partial "HOME-DELETED"
}

@test "S5: успех -> fstab c UUID p8, старый /home удалён после fstab, порядок верен" {
    run timeout 60 bash "${REPO_DIR}/tests/bats/scenarios/sh-migrate.sh" success
    assert_success
    assert_output --partial "RC=0"
    assert_output --partial "Сверка пройдена: копия идентична оригиналу."
    assert_output --partial "FSTAB-HAS-P8"
    assert_output --partial "FSTAB-BAK-EXISTS"
    assert_output --partial "PARTTABLE-COPIED"
    assert_output --partial "HOME-DELETED"
    assert_output --partial "HOME-EMPTY"
}

@test "S5 КРИТИЧЕСКИЙ: сбой rsync копии -> die до сверки и fstab" {
    run timeout 60 bash "${REPO_DIR}/tests/bats/scenarios/sh-migrate.sh" rsync-fail
    assert_failure
    assert_output --partial "RC=1"
    assert_output --partial "HOME-INTACT"
    assert_output --partial "FSTAB-WITHOUT-P8"
    refute_output --partial "FSTAB-HAS-P8"
    refute_output --partial "Сверка пройдена"
}
