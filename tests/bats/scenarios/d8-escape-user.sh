#!/usr/bin/env bash
# U-D8: generate_autounattend со спец-символьными USERNAME/HOSTNAME.
# Аргументы: $1 — USERNAME, $2 — HOSTNAME,
#            $3 — ожидаемое <Name>, $4 — ожидаемый <ComputerName>.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scenario_init deploy
# shellcheck disable=SC1091
source "${REPO_DIR}/deploy.sh" >/dev/null 2>&1
username="$1"
host="$2"
expected_name="$3"
expected_computer="$4"
USERNAME="$username"
HOSTNAME="$host"
TIMEZONE="Europe/Moscow"
WIN_PASSWORD="pw"
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
n_name=$(grep -Fc "<Name>${expected_name}</Name>" "$xml")
if [[ "$n_name" -ne 1 ]]; then
    echo "RC=1"; echo "FAIL: <Name>${expected_name}</Name> найден $n_name раз (ожидался 1)"; rc=1
fi
n_computer=$(grep -Fc "<ComputerName>${expected_computer}</ComputerName>" "$xml")
if [[ "$n_computer" -ne 1 ]]; then
    echo "RC=1"; echo "FAIL: <ComputerName>${expected_computer}</ComputerName> найден $n_computer раз (ожидался 1)"; rc=1
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
    echo "OK: USERNAME/HOSTNAME экранированы корректно"
fi
scenario_cleanup
