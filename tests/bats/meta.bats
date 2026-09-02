#!/usr/bin/env bats
load 'helpers'

# ==============================================================================
# Метатесты (§7.7): детекторы и соответствие шаблон↔подстановка.
# M-1: check-files.sh ловит нарушения (BOM, $x:, CRLF).
# M-2: каждый плейсхолдер шаблона имеет sed-подстановку в deploy.sh.
# M-3: шаблон unattend — well-formed XML, FirstLogonCommands на месте.
# ==============================================================================

make_ps1_fixture() {
    local dir="$1" file="$2" body="$3"
    mkdir -p "$dir"
    printf '\xef\xbb\xbf%s\r\n' "$body" > "$dir/$file"
}

@test "M-1: check-files.sh пропускает корректный ps1" {
    local d
    d="$(mktemp -d)"
    # корректный ps1 по всем правилам: BOM+CRLF+SYNOPSIS+param(), без \$x:
    printf '\xef\xbb\xbf# good\r\n<#\r\n.SYNOPSIS\r\n    test\r\n#>\r\nparam()\r\n' > "$d/good.ps1"
    run bash "${REPO_DIR}/check-files.sh" "$d"
    assert_success
    rm -rf "$d"
}

@test "M-1: check-files.sh ловит ps1 без BOM" {
    local d
    d="$(mktemp -d)"
    mkdir -p "$d"
    printf '# no bom here\n' > "$d/bad.ps1"
    run bash "${REPO_DIR}/check-files.sh" "$d"
    assert_failure
    assert_output --partial "отсутствует BOM"
    rm -rf "$d"
}

@test "M-1: check-files.sh ловит \$x: в строках ps1 (исторический класс ошибок)" {
    local d
    d="$(mktemp -d)"
    # BOM и CRLF на месте — проверяем именно детектор \$var:
    make_ps1_fixture "$d" "bad.ps1" 'Write-Host "тест $x: текст"'
    run bash "${REPO_DIR}/check-files.sh" "$d"
    assert_failure
    assert_output --partial "недопустимая ссылка"
    rm -rf "$d"
}

@test "M-1: check-files.sh ловит LF без CRLF в ps1" {
    local d
    d="$(mktemp -d)"
    mkdir -p "$d"
    printf '\xef\xbb\xbf# bom but unix newlines\n' > "$d/bad.ps1"
    run bash "${REPO_DIR}/check-files.sh" "$d"
    assert_failure
    assert_output --partial "CRLF"
    rm -rf "$d"
}

@test "M-2: каждый плейсхолдер шаблона имеет sed-подстановку в deploy.sh" {
    local ph placeholders
    placeholders="$(grep -o '__[A-Z_]*__' "${REPO_DIR}/templates/unattend.xml.template" | sort -u)"
    [[ -n "$placeholders" ]] || bats::fail "в шаблоне не найдено ни одного плейсхолдера"
    while read -r ph; do
        grep -q "s/${ph}/" "${REPO_DIR}/deploy.sh" || \
            bats::fail "плейсхолдер ${ph} есть в шаблоне, но нет подстановки в deploy.sh"
    done <<<"$placeholders"
    # и обратное: в deploy.sh не подставляется то, чего нет в шаблоне
    local used
    used="$(grep -o 's/__[A-Z_]*__/' "${REPO_DIR}/deploy.sh" | sed 's|^s/||; s|/$||' | sort -u)"
    while read -r ph; do
        grep -qF "$ph" "${REPO_DIR}/templates/unattend.xml.template" || \
            bats::fail "deploy.sh подставляет ${ph}, которого нет в шаблоне"
    done <<<"$used"
}

@test "M-3: unattend.xml.template — well-formed XML + FirstLogonCommands (телеметрия)" {
    local tpl="${REPO_DIR}/templates/unattend.xml.template"
    if command -v xmllint >/dev/null 2>&1; then
        xmllint --noout "$tpl"
    else
        skip "xmllint недоступен"
    fi
    grep -q '<FirstLogonCommands>' "$tpl" || bats::fail "нет <FirstLogonCommands> в шаблоне"
    grep -q 'AllowTelemetry' "$tpl" || bats::fail "нет AllowTelemetry (телеметрия) в шаблоне"
}
