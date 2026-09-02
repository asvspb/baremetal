#!/usr/bin/env bash
# ==============================================================================
# tests/setup.sh — установка зависимостей тестовой системы (idempotent)
#
# Ставит в tests/.deps/:
#   • bats-core + bats-support + bats-assert (клоны git, версии зафиксированы)
#   • pwsh 7 (tarball с GitHub; best-effort — при неудаче уровень L1 = SKIP)
# Через apt (нужен sudo, best-effort):
#   • xmllint (libxml2-utils) — валидация autounattend.xml
#
# Повторный запуск безопасен: уже установленное не перекачивается.
# ==============================================================================
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPS_DIR="${TESTS_DIR}/.deps"
mkdir -p "$DEPS_DIR"

log()  { echo -e "\033[1;34m[setup]\033[0m $*"; }
warn() { echo -e "\033[1;33m[setup]\033[0m $*" >&2; }

# ------------------------------------------------------------------------------
# 1. bats-core / bats-support / bats-assert — клоны по зафиксированным тегам
# ------------------------------------------------------------------------------
clone_pinned() {
    local repo="$1" tag="$2" dir="$3"
    if [[ -d "$dir/.git" ]]; then
        log "уже склонирован: ${dir##*/}"
    else
        log "клонирование ${repo} (${tag})..."
        rm -rf "$dir"
        git clone --quiet --depth 1 --branch "$tag" "https://github.com/bats-core/${repo}.git" "$dir"
    fi
}

clone_pinned bats-core    v1.11.0 "$DEPS_DIR/bats-core"
clone_pinned bats-support v0.3.0 "$DEPS_DIR/bats-support"
clone_pinned bats-assert  v2.1.0 "$DEPS_DIR/bats-assert"

# ------------------------------------------------------------------------------
# 2. xmllint (libxml2-utils) — best-effort через sudo
# ------------------------------------------------------------------------------
if command -v xmllint >/dev/null 2>&1; then
    log "xmllint уже установлен"
elif sudo -n apt-get install -y -qq libxml2-utils >/dev/null 2>&1; then
    log "xmllint установлен (libxml2-utils)"
else
    warn "xmllint недоступен (нет sudo/сети). U-D6: часть с xmllint будет пропущена, sed-проверки остаются."
fi

# ------------------------------------------------------------------------------
# 3. pwsh 7 (tarball) — best-effort; без него L1 = SKIP (штатная деградация §12)
# ------------------------------------------------------------------------------
PWSH_VERSION="7.4.6"
PWSH_DIR="$DEPS_DIR/pwsh"
if [[ -x "$PWSH_DIR/pwsh" ]]; then
    log "pwsh уже установлен: $PWSH_DIR/pwsh"
elif command -v pwsh >/dev/null 2>&1; then
    log "pwsh найден в PATH: $(command -v pwsh)"
else
    PWSH_URL="https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-x64.tar.gz"
    log "попытка скачать pwsh ${PWSH_VERSION} (~70 МБ)..."
    if timeout 300 wget -q "$PWSH_URL" -O "$DEPS_DIR/pwsh.tar.gz"; then
        rm -rf "$PWSH_DIR" && mkdir -p "$PWSH_DIR"
        if tar -xzf "$DEPS_DIR/pwsh.tar.gz" -C "$PWSH_DIR" && chmod +x "$PWSH_DIR/pwsh"; then
            rm -f "$DEPS_DIR/pwsh.tar.gz"
            log "pwsh установлен: $PWSH_DIR/pwsh"
        else
            warn "распаковка pwsh не удалась — L1 будет SKIP"
        fi
    else
        warn "скачать pwsh не удалось (нет сети?) — L1 будет SKIP (см. TEST-SPEC §12)"
        rm -f "$DEPS_DIR/pwsh.tar.gz"
    fi
fi

# ------------------------------------------------------------------------------
# 4. Сводка окружения
# ------------------------------------------------------------------------------
log "— проверка окружения —"
sudo -n true 2>/dev/null && log "sudo -n: доступен (L4/L5 можно запускать)" || warn "sudo -n недоступен: L4/L5 будут SKIP"
command -v xmllint >/dev/null 2>&1 && log "xmllint: ok" || warn "xmllint: нет"
[[ -x "$PWSH_DIR/pwsh" ]] || command -v pwsh >/dev/null 2>&1 && log "pwsh: ok" || warn "pwsh: нет (L1 SKIP)"
"$DEPS_DIR/bats-core/bin/bats" --version 2>/dev/null | head -n 1 || warn "bats: не работает?!"
log "готово."
