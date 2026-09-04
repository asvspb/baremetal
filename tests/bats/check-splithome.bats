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
    assert_output --partial "--recovery"
}

@test "REC-1: --recovery -> памятка восстановления (симптомы + лечение)" {
    run timeout 60 bash "${REPO_DIR}/split-home.sh" --recovery
    assert_success
    assert_output --partial "ПАМЯТКА: система не грузится после разделения"
    assert_output --partial "emergency mode"
    assert_output --partial "grub-install --efi-directory=/boot/efi"
    assert_output --partial "parttable-before-split-*.bak"
    assert_output --partial "1058140160s 1745784831s"
    assert_output --partial "ПРЕРВАЛСЯ ДО ЗАВЕРШЕНИЯ"
    assert_output --partial "resizepart 7 1745784831s"
    refute_output --partial "mkfs.ext4 -F"
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
    assert_output --partial "FSTAB-WITHOUT-P9"
    refute_output --partial "FSTAB-HAS-P9"
    refute_output --partial "HOME-DELETED"
}

@test "S5: успех -> fstab c UUID p9, старый /home удалён после fstab, порядок верен" {
    run timeout 60 bash "${REPO_DIR}/tests/bats/scenarios/sh-migrate.sh" success
    assert_success
    assert_output --partial "RC=0"
    assert_output --partial "Сверка пройдена: копия идентична оригиналу."
    assert_output --partial "FSTAB-HAS-P9"
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
    assert_output --partial "FSTAB-WITHOUT-P9"
    refute_output --partial "FSTAB-HAS-P9"
    refute_output --partial "Сверка пройдена"
}

# ---------- A1: охрана разметки (сценарии sh-guard-layout.sh, PART_SYS_ROOT) ----------

@test "A1: охрана — корректные отпечатки -> layout ok, мутирующих вызовов нет" {
    run timeout 60 bash "${REPO_DIR}/tests/bats/scenarios/sh-guard-layout.sh" all-good
    assert_success
    assert_output --partial "LAYOUT-OK"
    assert_output --partial "NO-MUTATING"
}

@test "A1: p9 уже существует -> die «операция уже выполнялась»" {
    run timeout 60 bash "${REPO_DIR}/tests/bats/scenarios/sh-guard-layout.sh" p9-exists
    assert_failure
    assert_output --partial "RC=1"
    assert_output --partial "Раздел /dev/fakep9 уже существует"
    assert_output --partial "NO-MUTATING"
}

@test "A1: нет раздела Distr (p8) -> die «разметка не соответствует»" {
    run timeout 60 bash "${REPO_DIR}/tests/bats/scenarios/sh-guard-layout.sh" p8-missing
    assert_failure
    assert_output --partial "RC=1"
    assert_output --partial "не найден раздел Distr (/dev/fakep8)"
}

@test "A1: отпечаток Distr не сошёлся (не exfat) -> die «обновите константы»" {
    run timeout 60 bash "${REPO_DIR}/tests/bats/scenarios/sh-guard-layout.sh" p8-fingerprint
    assert_failure
    assert_output --partial "RC=1"
    assert_output --partial "Тип ФС на /dev/fakep8: 'vfat', ожидался exfat"
}

@test "A1: размер p7 не совпал с отпечатком -> die «обновите константы»" {
    run timeout 60 bash "${REPO_DIR}/tests/bats/scenarios/sh-guard-layout.sh" p7-size
    assert_failure
    assert_output --partial "RC=1"
    assert_output --partial "Размер /dev/fakep7"
    assert_output --partial "не совпадает с ожидаемым (1107075072)"
}

# ---------- A9: освобождение NVMe-разделов до preflight (sh-release-mounts.sh) ----------

@test "A9: Live-автомонтирования -> авто-umount обеих nvme-точек, rc 0, без мутаций" {
    run timeout 60 bash "${REPO_DIR}/tests/bats/scenarios/sh-release-mounts.sh" ok
    assert_success
    assert_output --partial "RC=0"
    assert_output --partial "RELEASE-OK"
    assert_output --partial "umount /run/media/ubuntu/1b8e3e50-2e22-4088-a3a5-396293780ff2"
    assert_output --partial "umount /run/media/ubuntu/Distr"
    assert_output --partial "NO-MUTATING"
}

@test "A9 КРИТИЧЕСКИЙ: точка занята (файловый менеджер) -> umount сбой -> die ДО изменений" {
    run timeout 60 bash "${REPO_DIR}/tests/bats/scenarios/sh-release-mounts.sh" busy
    assert_failure
    assert_output --partial "RC=1"
    assert_output --partial "Не удалось отмонтировать"
    assert_output --partial "NO-MUTATING"
}
