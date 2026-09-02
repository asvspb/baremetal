#!/usr/bin/env bats
load 'helpers'

# ==============================================================================
# L2/L3: deploy.sh — юниты (U-D1, U-D2) и интеграция на заглушках (T3).
# deploy.sh вызывается через `bash -c 'source ...'`: guard делает source
# безопасным (main не выполняется, RAM-копия не создаётся).
# ==============================================================================

# source deploy.sh в изолированном bash; доп. команда — аргументом
deploy_run() {
    local extra="$1"
    bash -c "set -uo pipefail; source '${REPO_DIR}/deploy.sh' >/dev/null 2>&1; ${extra}"
}

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
