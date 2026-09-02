#!/usr/bin/env bats
load 'helpers'

# ==============================================================================
# L2/L3: deploy.sh — юниты (U-D1, U-D2) и интеграция на заглушках.
# Интеграционные проверки выполняются сценариями из tests/bats/scenarios/:
# сценарий сам изолирует окружение, ставит заглушки и проверяет безопасность
# (целевое устройство — несуществующее /dev/fakenvme0n1 или /dev/fakedisk).
# ==============================================================================

# source deploy.sh в изолированном bash; доп. команда — аргументом
deploy_run() {
    local extra="$1"
    bash -c "set -uo pipefail; source '${REPO_DIR}/deploy.sh' >/dev/null 2>&1; ${extra}"
}

SCEN="${REPO_DIR}/tests/bats/scenarios"

# ---------- L2: чистые функции ----------

@test "U-D1: iana_to_windows_tz — Москва -> Russian Standard Time" {
    run deploy_run "iana_to_windows_tz 'Europe/Moscow'"
    assert_success
    assert_output "Russian Standard Time"
}

@test "U-D1: iana_to_windows_tz — Калининград -> Kaliningrad Standard Time" {
    run deploy_run "iana_to_windows_tz 'Europe/Kaliningrad'"
    assert_success
    assert_output "Kaliningrad Standard Time"
}

@test "U-D1: iana_to_windows_tz — Новосибирск -> N. Central Asia Standard Time" {
    run deploy_run "iana_to_windows_tz 'Asia/Novosibirsk'"
    assert_success
    assert_output "N. Central Asia Standard Time"
}

@test "U-D1: iana_to_windows_tz — Владивосток -> Vladivostok Standard Time" {
    run deploy_run "iana_to_windows_tz 'Asia/Vladivostok'"
    assert_success
    assert_output "Vladivostok Standard Time"
}

@test "U-D1: iana_to_windows_tz — неизвестная зона -> дефолт Russian Standard Time" {
    run deploy_run "iana_to_windows_tz 'Mars/Olympus'"
    assert_success
    assert_output "Russian Standard Time"
}

@test "U-D2: part_dev — nvme0n1 получает суффикс p" {
    run deploy_run "part_dev /dev/nvme0n1 6"
    assert_success
    assert_output "/dev/nvme0n1p6"
}

@test "U-D2: part_dev — sda без суффикса" {
    run deploy_run "part_dev /dev/sda 6"
    assert_success
    assert_output "/dev/sda6"
}

@test "U-D2: part_dev — loop0 (цифра в конце) получает суффикс p" {
    run deploy_run "part_dev /dev/loop0 1"
    assert_success
    assert_output "/dev/loop0p1"
}

# ---------- L3: CLI и интеграция на заглушках ----------

@test "U-D3: --disk без аргумента -> die" {
    run timeout 60 bash "${SCEN}/d3-cli-errors.sh" disk-noarg
    assert_failure
    assert_output --partial "Укажите диск после --disk"
}

@test "U-D3: неизвестный флаг -> die" {
    run timeout 60 bash "${SCEN}/d3-cli-errors.sh" unknown-flag
    assert_failure
    assert_output --partial "Неизвестный параметр: --frobnicate"
}

@test "U-D3: --help -> exit 0 и заголовок справки" {
    run timeout 60 bash "${SCEN}/d3-cli-errors.sh" help
    assert_success
    assert_output --partial "Использование: sudo bash deploy.sh"
}

@test "U-D4: detect_disk AUTO — все кандидаты USB -> fallback nvme0n1" {
    run timeout 60 bash "${SCEN}/d4-detect-disk.sh" all-usb
    assert_success
    assert_output --partial "TARGET=/dev/nvme0n1"
}

@test "U-D4: detect_disk AUTO — ничего не USB -> первый существующий (nvme0n1)" {
    run timeout 60 bash "${SCEN}/d4-detect-disk.sh" none-usb
    assert_success
    assert_output --partial "TARGET=/dev/nvme0n1"
}

@test "U-D4: detect_disk AUTO — nvme считается USB -> выбирается sda" {
    run timeout 60 bash "${SCEN}/d4-detect-disk.sh" usb-only-nvme
    if [[ ! -b /dev/sda ]]; then skip "на этой машине нет /dev/sda"; fi
    assert_success
    assert_output --partial "TARGET=/dev/sda"
}

@test "U-D5: find_isos находит win/ubuntu ISO в SCRIPT_DIR" {
    run timeout 60 bash "${SCEN}/d5-find-isos.sh"
    assert_success
    assert_output --partial "WIN=fake-win.iso"
    assert_output --partial "UBU=fake-ubuntu.iso"
}

@test "U-D6: generate_autounattend — пароль p&a<b>\"c/d экранируется" {
    run timeout 120 bash "${SCEN}/d6-generate-password.sh" 'p&a<b>"c/d' 'p&amp;a&lt;b&gt;&quot;c/d'
    assert_success
    assert_output --partial "RC=0"
}

@test "U-D6: generate_autounattend — пароль из слэшей // экранируется" {
    run timeout 120 bash "${SCEN}/d6-generate-password.sh" '//' '//'
    assert_success
    assert_output --partial "RC=0"
}

@test "U-D6: generate_autounattend — пустой пароль без плейсхолдеров" {
    run timeout 120 bash "${SCEN}/d6-generate-password.sh" '' ''
    assert_success
    assert_output --partial "RC=0"
}

@test "U-D6: generate_autounattend — кириллица + амперсанд экранируется" {
    run timeout 120 bash "${SCEN}/d6-generate-password.sh" 'п@роль&123' 'п@роль&amp;123'
    assert_success
    assert_output --partial "RC=0"
}

@test "U-D7: без ISO Ubuntu (не dry-run) -> die про debootstrap" {
    run timeout 60 bash "${SCEN}/d7-no-ubuntu-iso.sh"
    assert_failure
    assert_output --partial "Требуется ISO Ubuntu (debootstrap не поддерживается)"
}

@test "I-D1: PREP_DISK — последовательность parted/mkfs и autounattend.xml" {
    run timeout 120 bash "${SCEN}/d1-prep-sequence.sh"
    assert_success
    assert_output --partial "OK: последовательность PREP_DISK корректна"
    refute_output --partial "SAFETY-FAIL"
}

@test "I-D2: enable_os_prober дописывает GRUB_DISABLE_OS_PROBER=false" {
    run timeout 60 bash "${SCEN}/d2-osprober.sh"
    assert_success
    assert_output --partial "OK"
    assert_output --partial "COUNT=1"
    assert_output --partial "VALUE=GRUB_DISABLE_OS_PROBER=false"
}

@test "U-D6: весь корпус паролей из fixtures/passwords.txt валиден" {
    local pw
    while IFS= read -r pw; do
        run timeout 120 bash "${SCEN}/d6-generate-password.sh" "$pw" '__ANY__'
        # __ANY__ запрещает проверку точного экранирования; сценарий проверяет
        # отсутствие неразрешённых плейсхолдеров и xmllint-валидность
        assert_success
        assert_output --partial "RC=0"
        refute_output --partial "FAIL"
    done < <(grep -v '^$' "${REPO_DIR}/tests/fixtures/passwords.txt" || true)
}
