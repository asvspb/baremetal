#!/usr/bin/env bash
# U-D3: CLI deploy.sh — ошибки разбора аргументов (подпроцесс; die в parse_args
# срабатывает раньше EUID-проверки, поэтому тест проходит без root)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rc=0
out=""
case "${1:-}" in
    disk-noarg)
        out=$(bash "${REPO_DIR}/deploy.sh" --disk 2>&1) || rc=$? ;;
    unknown-flag)
        out=$(bash "${REPO_DIR}/deploy.sh" --frobnicate 2>&1) || rc=$? ;;
    help)
        out=$(bash "${REPO_DIR}/deploy.sh" --help 2>&1) || rc=$? ;;
    *) echo "RC=2"; echo "unknown variant"; exit 2 ;;
esac
echo "RC=$rc"
echo "$out"
scenario_cleanup
exit "$rc"
