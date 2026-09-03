#!/usr/bin/env bats
load 'helpers'

# ==============================================================================
# L2/L3: make-boot-usb.sh — юниты (U-M1) и интеграция на заглушках (I-M1..I-M8).
# Целевые «диски» в L3 — несуществующие /dev/fakedisk*; каждый критический
# сценарий дополнительно проверяет, что мутирующие команды не вызывались.
# ==============================================================================

# source make-boot-usb.sh в изолированном bash с заглушками в PATH
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

SCEN="${REPO_DIR}/tests/bats/scenarios"

# ---------- L2: чистые функции ----------

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

# ---------- L3: интеграция на заглушках ----------

@test "I-M1: choose_backup_dir — tmpfs -> /var/tmp (Live-среда)" {
    run timeout 60 bash "${SCEN}/m1-backup-dir.sh" tmpfs-default
    assert_success
    assert_output --partial "RESULT_DIR=/var/tmp/usb_backup_"
    assert_output --partial "OK"
}

@test "I-M1: choose_backup_dir — tmpfs + введённый пользователем путь" {
    run timeout 60 bash "${SCEN}/m1-backup-dir.sh" tmpfs-custom
    assert_success
    assert_output --partial "OK"
}

@test "I-M1: choose_backup_dir — обычный /tmp (не tmpfs) -> /tmp/usb_backup_" {
    run timeout 60 bash "${SCEN}/m1-backup-dir.sh" ext4-default
    assert_success
    assert_output --partial "RESULT_DIR=/tmp/usb_backup_"
    assert_output --partial "OK"
}

@test "I-M2: check_backup_space — мало места -> die ДО копирования" {
    run timeout 60 bash "${SCEN}/m2-backup-space.sh" little
    assert_failure
    assert_output --partial "Недостаточно места для бэкапа"
    assert_output --partial "NO-MUTATIONS"
}

@test "I-M2: check_backup_space — места достаточно -> rc 0" {
    run timeout 60 bash "${SCEN}/m2-backup-space.sh" enough
    assert_success
    assert_output --partial "RC=0"
}

@test "I-M3 КРИТИЧЕСКИЙ: сбой rsync на бэкапе -> die, флешка НЕ тронута" {
    run timeout 60 bash "${SCEN}/m3-backup-fail.sh" rsync-fail
    assert_failure
    assert_output --partial "Сбой копирования данных с раздела"
    assert_output --partial "Бэкап сохранен"
    assert_output --partial "BACKUP-KEPT"
    assert_output --partial "USB-UNTOUCHED"
    refute_output --partial "USB-TOUCHED"
}

@test "I-M3 КРИТИЧЕСКИЙ: сбой cp (ISO) на бэкапе -> die, флешка НЕ тронута" {
    run timeout 60 bash "${SCEN}/m3-backup-fail.sh" cp-fail
    assert_failure
    assert_output --partial "Сбой копирования ISO-образов с раздела"
    assert_output --partial "Бэкап сохранен"
    assert_output --partial "BACKUP-KEPT"
    assert_output --partial "USB-UNTOUCHED"
}

@test "I-M4 КРИТИЧЕСКИЙ: сверка ISO не сошлась -> бэкап НЕ удалён" {
    run timeout 60 bash "${SCEN}/m4-verify-mismatch.sh" iso
    assert_failure
    assert_output --partial "ISO-образы восстановлены с ошибками"
    assert_output --partial "BACKUP-KEPT"
}

@test "I-M4 КРИТИЧЕСКИЙ: сверка данных не сошлась -> бэкап НЕ удалён" {
    run timeout 60 bash "${SCEN}/m4-verify-mismatch.sh" data
    assert_failure
    assert_output --partial "Данные восстановлены с ошибками"
    assert_output --partial "BACKUP-KEPT"
}

@test "I-M5: успешный цикл бэкап -> разметка -> восстановление -> бэкап удалён" {
    run timeout 120 bash "${SCEN}/m5-success-cycle.sh"
    assert_success
    assert_output --partial "RC=0"
    assert_output --partial "PARTED-CALLED"
    assert_output --partial "VENTOY-CALLED"
    assert_output --partial "ISO-RESTORED"
    assert_output --partial "DATA-RESTORED"
    assert_output --partial "NESTED-RESTORED"
    assert_output --partial "BACKUP-DELETED"
}

@test "I-M6: copy_deploy_package кладёт пакет на раздел данных" {
    run timeout 60 bash "${SCEN}/m6-copy-package.sh"
    assert_success
    assert_output --partial "RC=0"
    assert_output --partial "HAS deploy.sh"
    assert_output --partial "HAS deploy.conf"
    assert_output --partial "HAS split-home.sh"
    assert_output --partial "HAS templates/unattend.xml.template"
}

@test "I-M7: интерактивная настройка через piped-ввод -> верные параметры" {
    run timeout 60 bash "${SCEN}/m7-interactive-config.sh"
    assert_success
    assert_output --partial "HAS-CONFIG-LINE"
    assert_output --partial "DATA_FS=exfat VENTOY_SIZE_G=8 LABEL_P1=FD-0 LABEL_P3=DATA-0"
}

@test "I-M8: защита от nvme — guard присутствует, nvme не предлагается к выбору" {
    run timeout 60 bash "${SCEN}/m8-nvme-guard.sh"
    assert_success
    assert_output --partial "GUARD-STATIC=PRESENT"
    assert_output --partial "NVME-NOT-OFFERED"
}

# ---------- Регрессия древесных префиксов lsblk (реальный запуск 2026-09-02) ----------

@test "I-M9: перечисление разделов плоским списком (-l), без префиксов дерева" {
    # Статика: все точки перечисления используют -nlpo (не -npo без -l);
    # шаблон покрывает и вызов с колонками NAME,PARTLABEL,PARTTYPE
    run grep -c 'lsblk -nlpo NAME' "${REPO_DIR}/make-boot-usb.sh"
    assert_success
    assert_output "2"
    run bash -c "grep -E 'lsblk -npo NAME' '${REPO_DIR}/make-boot-usb.sh' | grep -v -- '-nlpo' && exit 1 || exit 0"
    assert_success
    # Функционально: реальный lsblk с -nlpo не отдаёт древесные префиксы
    local disk
    disk="$(lsblk -dpno NAME | head -n 1)"
    if [[ -z "$disk" ]]; then skip "нет блочных устройств"; fi
    run bash -c "lsblk -nlpo NAME \"$disk\""
    assert_success
    refute_output --partial $'\u251c\u2500'
    refute_output --partial $'\u2514\u2500'
}

# ---------- Регрессия бэкапа VTOYEFI (реальный запуск 2026-09-02) ----------

@test "I-M10: служебный раздел VTOYEFI исключен из бэкапа пользовательских данных" {
    # Статика: перечисление для бэкапа различает разделы по PARTLABEL/PARTTYPE
    run grep -c 'lsblk -nlpo NAME,PARTLABEL,PARTTYPE' "${REPO_DIR}/make-boot-usb.sh"
    assert_success
    assert_output "1"
    # Функционально: mount для VTOYEFI настроен на сбой — до фикса бэкап
    # монтировал его и умирал; после фикса раздел даже не пытаются открыть,
    # а данные пользовательских разделов попадают в бэкап целиком.
    run timeout 60 bash "${SCEN}/m10-vtoyefi-excluded.sh"
    assert_success
    assert_output --partial "RC=0"
    assert_output --partial "DATA-BACKED-UP"
    assert_output --partial "NO-VTOY-JUNK"
    assert_output --partial "VTOYEFI-SKIPPED"
    refute_output --partial "VTOYEFI-MOUNTED"
}
