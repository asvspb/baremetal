#!/usr/bin/env bash
# U-D6: generate_autounattend со спец-символьными паролями.
# Аргументы: $1 — пароль, $2 — ожидаемое XML-экранированное значение.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scenario_init deploy
# shellcheck disable=SC1091
source "${REPO_DIR}/deploy.sh" >/dev/null 2>&1
password="$1"
expected="$2"
USERNAME="testuser"
HOSTNAME="testhost"
TIMEZONE="Europe/Moscow"
WIN_PASSWORD="$password"
WIN_ISO=""
ORIG_SCRIPT_DIR="${SCEN_TMP}"
SCRIPT_DIR="${REPO_DIR}"
DRY=0
generate_autounattend >/dev/null 2>&1 || { echo "RC=1"; echo "generate_autounattend завершился ошибкой"; scenario_cleanup; exit 0; }
xml="${SCEN_TMP}/autounattend.xml"
[[ -f "$xml" ]] || { echo "RC=1"; echo "autounattend.xml не создан"; scenario_cleanup; exit 0; }
rc=0
if grep -Eq '__[A-Z_]+__' "$xml"; then
    echo "RC=1"; echo "FAIL: остались неразрешённые плейсхолдеры"; rc=1
fi
if [[ "$expected" != "__ANY__" ]]; then
    n=$(grep -Fc "<Value>${expected}</Value>" "$xml")
    if [[ "$n" -ne 2 ]]; then
        echo "RC=1"; echo "FAIL: пароль вставлен $n раз (ожидалось 2): '<Value>${expected}</Value>'"; rc=1
    fi
fi
if command -v xmllint >/dev/null 2>&1; then
    if ! xmllint --noout "$xml" 2>&1; then
        echo "RC=1"; echo "FAIL: xmllint отклонил XML"; rc=1
    fi
else
    echo "XMLLINT=SKIPPED"
fi
if (( rc == 0 )); then
    echo "RC=0"
    echo "OK: пароль экранирован корректно"
fi
scenario_cleanup
