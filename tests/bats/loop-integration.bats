#!/usr/bin/env bats
load 'helpers'

# ==============================================================================
# L4: интеграция на loop-устройствах (root; реальные parted/mkfs — ТОЛЬКО на
# /dev/loop*). Каждый тест assert-ом проверяет имя целевого устройства.
#
# ОТКЛОНЕНИЕ ОТ §7.4 (осознанное): образ 520G (sparse, truncate), а не 8G —
# размеры разделов зашиты в deploy.conf (сумма ~501 GiB), на 8G parted
# откажется создавать разделы. Sparse-файл реального места не занимает.
# ==============================================================================

LOOP_IMG=""
LOOP_DEV=""

loop_setup() {
    [[ $EUID -eq 0 ]] || skip "L4 требует root (запускайте: sudo -n make test-loop)"
    command -v losetup >/dev/null || skip "losetup недоступен"
    LOOP_IMG="$(mktemp -d)/loop-deploy.img"
    truncate -s 520G "$LOOP_IMG"
    LOOP_DEV="$(losetup -fP --show "$LOOP_IMG")"
    # защита: целимся ТОЛЬКО в loop-устройство
    [[ "$LOOP_DEV" =~ ^/dev/loop[0-9]+$ ]] || {
        loop_teardown
        bats::fail "losetup вернул не-loop устройство: $LOOP_DEV"
    }
}

loop_teardown() {
    if [[ -n "${LOOP_DEV:-}" && "$LOOP_DEV" =~ ^/dev/loop[0-9]+$ ]]; then
        losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
    if [[ -n "${LOOP_IMG:-}" && -f "$LOOP_IMG" ]]; then
        rm -f "$LOOP_IMG"
    fi
    LOOP_DEV=""; LOOP_IMG=""
}

run_prep() {
    bash "${REPO_DIR}/deploy.sh" --prep-disk --disk "$LOOP_DEV" --yes >/dev/null 2>&1
}

@test "L-T1: PREP_DISK на loop — 7 разделов, корректные ФС, autounattend" {
    loop_setup
    run run_prep
    assert_success

    # sfdisk: 7 разделов
    local types
    types="$(sfdisk -d "$LOOP_DEV" 2>/dev/null)"
    local n
    n=$(grep -cE "^${LOOP_DEV}p[1-7] :" <<<"$types")
    assert_equal "$n" "7"

    # типы GPT: EFI (C12A...), MSR (E3C9...), Windows/Shared (EBD0... basic data), Recovery (DE94... WinRE)
    grep -q "${LOOP_DEV}p1 : start=" <<<"$types"
    grep -qi "type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B" <<<"$types"
    grep -qi "type=E3C9E316-0B5C-4DB8-817D-F92DF00215AE" <<<"$types"
    grep -qi "type=DE94BBA4-06D1-4D40-A16A-BFD50179D6AC" <<<"$types"
    grep -q "${LOOP_DEV}p4" <<<"$types" && grep -q "RequiredPartition" <<<"$types"

    # ФС на разделах (mkfs реальный)
    assert_equal "$(lsblk -no FSTYPE "${LOOP_DEV}p1")" "vfat"
    assert_equal "$(lsblk -no FSTYPE "${LOOP_DEV}p3")" "ntfs"
    assert_equal "$(lsblk -no FSTYPE "${LOOP_DEV}p4")" "ntfs"
    assert_equal "$(lsblk -no FSTYPE "${LOOP_DEV}p5")" "exfat"
    assert_equal "$(lsblk -no FSTYPE "${LOOP_DEV}p6")" "ext4"
    assert_equal "$(lsblk -no FSTYPE "${LOOP_DEV}p7")" "ext4"

    loop_teardown
}

@test "L-T2: повторный PREP_DISK поверх — exit 0 (чистая переразметка)" {
    loop_setup
    run run_prep
    assert_success
    run run_prep
    assert_success
    local n
    n=$(sfdisk -d "$LOOP_DEV" 2>/dev/null | grep -cE "^${LOOP_DEV}p[1-7] :")
    assert_equal "$n" "7"
    loop_teardown
}

@test "L-T3: autounattend.xml после PREP_DISK валиден, PartitionID=3" {
    loop_setup
    run run_prep
    assert_success

    # deploy.sh работает через RAM-копию: autounattend.xml рядом с ней
    local xml="/tmp/deploy-baremetal/autounattend.xml"
    [[ -f "$xml" ]] || {
        loop_teardown
        bats::fail "autounattend.xml не создан: $xml"
    }
    if command -v xmllint >/dev/null 2>&1; then
        run xmllint --noout "$xml"
        assert_success
    else
        skip "xmllint недоступен"
    fi
    local pid
    pid=$(grep -oP '(?<=<PartitionID>)[0-9]+(?=</PartitionID>)' "$xml" | head -n 1)
    assert_equal "$pid" "3"

    loop_teardown
}
