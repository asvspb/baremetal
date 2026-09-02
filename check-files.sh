#!/usr/bin/env bash
# ==============================================================================
# check-files.sh — Проверка служебных файлов проекта deploy-baremetal
#
# Для *.ps1 (кириллица, Windows PowerShell 5.1):
#   • BOM (EF BB BF) в начале файла
#   • переводы строк CRLF
#   • ровно один блок .SYNOPSIS и один param()
#   • отсутствие «умных» кавычек U+201C/U+201D/U+2018/U+2019
#   • баланс фигурных скобок {} и круглых скобок ()
# Для *.sh:
#   • синтаксис bash -n
#
# Подключен как git pre-commit hook (.git/hooks/pre-commit).
# ==============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${1:-$SCRIPT_DIR}"

failures=0

check_ps1() {
    local file="$1"
    local ok=1

    # 1. BOM в первых трёх байтах
    if ! head -c 3 "$file" | od -An -tx1 | grep -q 'ef bb bf'; then
        echo "  ✗ $file: отсутствует BOM (EF BB BF)" >&2
        ok=0
    fi

    # 2/3/4/5/6: единый блок проверок через python3 (не зависит от локали)
    if ! python3 - "$file" <<'PYEOF'
import sys
p = sys.argv[1]
raw = open(p, 'rb').read()
def err(msg):
    print(msg, file=sys.stderr)
# CRLF-проверка: файл не должен содержать одиночных LF без CR
if b'\r\n' not in raw and raw:
    err('нет переводов CRLF')
    sys.exit(1)
# проверка на «умные» кавычки
for ch in ('\u201c', '\u201d', '\u2018', '\u2019'):
    if ch in raw.decode('utf-8-sig'):
        err(f'найдена «умная» кавычка {ch!r}')
        sys.exit(1)
# один SYNOPSIS и один param()
text = raw.decode('utf-8-sig')
if text.count('.SYNOPSIS') != 1:
    err(f'.SYNOPSIS встречается {text.count(".SYNOPSIS")} раз')
    sys.exit(1)
if text.count('param()') != 1:
    err(f'param() встречается {text.count("param()")} раз')
    sys.exit(1)
# баланс скобок
if text.count('{') != text.count('}') or text.count('(') != text.count(')'):
    err('дисбаланс скобок {{}} / ()')
    sys.exit(1)
PYEOF
    then
        echo "  ✗ $file: нарушение правил кодировки/структуры (см. выше)" >&2
        ok=0
    fi

    if (( ok == 0 )); then
        failures=$((failures + 1))
    fi
}

check_sh() {
    local file="$1"
    if ! bash -n "$file"; then
        echo "  ✗ $file: синтаксическая ошибка bash" >&2
        failures=$((failures + 1))
    fi
}

while IFS= read -r -d '' file; do
    check_ps1 "$file"
done < <(find "$ROOT_DIR" -name '*.ps1' -type f -print0)

while IFS= read -r -d '' file; do
    check_sh "$file"
done < <(find "$ROOT_DIR" -name '*.sh' -type f -print0)

if (( failures > 0 )); then
    echo "check-files: найдено ошибок: $failures" >&2
    exit 1
fi
echo "check-files: все файлы в порядке (ps1: BOM+CRLF+структура, sh: bash -n)."
exit 0
