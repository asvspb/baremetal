#!/usr/bin/env bats
# ==============================================================================
# L1: парсинг make-boot-usb.ps1 настоящим парсером PowerShell (pwsh 7).
# Без pwsh — SKIP (жёлтым), не провал: штатная деградация TEST-SPEC §12.
# ==============================================================================
load 'helpers'

PWSH_BIN=""
PS_COUNT="${REPO_DIR}/tests/bats/ps-parse-count.ps1"

setup() {
    if [[ -x "${REPO_DIR}/tests/.deps/pwsh/pwsh" ]]; then
        PWSH_BIN="${REPO_DIR}/tests/.deps/pwsh/pwsh"
    elif command -v pwsh >/dev/null 2>&1; then
        PWSH_BIN="$(command -v pwsh)"
    fi
}

@test "P-1: make-boot-usb.ps1 парсится pwsh без ошибок" {
    [[ -n "$PWSH_BIN" ]] || skip "pwsh недоступен — L1 SKIP (TEST-SPEC §12); статический контроль остаётся в check-files.sh"
    run timeout 180 "$PWSH_BIN" -NoProfile -File "$PS_COUNT" "$REPO_DIR/make-boot-usb.ps1"
    assert_success
    assert_output --regexp '^[0-9]+'
    local count
    count="$(echo "$output" | tail -n 1)"
    assert_equal "$count" "0"
}

@test "P-2: канарейка — строка с \$x: обязана давать ошибку парсинга" {
    [[ -n "$PWSH_BIN" ]] || skip "pwsh недоступен — L1 SKIP (TEST-SPEC §12)"
    local canary="${BATS_TEST_TMPDIR}/canary.ps1"
    {
        head -c 3 "$REPO_DIR/make-boot-usb.ps1"   # перенести BOM
        tail -c +4 "$REPO_DIR/make-boot-usb.ps1"
        printf 'Write-Host "тест $x: текст"\r\n'
    } > "$canary"
    run timeout 180 "$PWSH_BIN" -NoProfile -File "$PS_COUNT" "$canary"
    assert_success
    local count
    count="$(echo "$output" | tail -n 1)"
    assert_not_equal "$count" "0"
}
