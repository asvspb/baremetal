#!/usr/bin/env bash
# ==============================================================================
# make-stub.sh <cmd> <exit-код> [--stdout "текст"]
#
# Генератор универсальной заглушки в tests/stubs/bin/<cmd>.
# Заглушка пишет каждый вызов (argv + cwd) в "$STUB_LOG/<cmd>.log"
# (env STUB_LOG — каталог, по одному файлу на команду) и завершается
# указанным кодом, опционально печатая --stdout на stdout.
#
# Для команд с ветвящейся логикой (lsblk, df, udevadm, cp, rsync, dd,
# wget, curl) используйте готовые скрипты из tests/stubs/custom/.
# ==============================================================================
set -euo pipefail

usage() {
    echo "usage: make-stub.sh <cmd> <exit> [--stdout \"text\"]" >&2
    exit 2
}

[[ $# -ge 2 ]] || usage
cmd="$1"; exit_code="$2"; shift 2
stdout_text=""
if [[ "${1:-}" == "--stdout" ]]; then
    [[ $# -ge 2 ]] || usage
    stdout_text="$2"
fi

bin_dir="${STUB_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin}"
mkdir -p "$bin_dir"

cat > "$bin_dir/$cmd" <<EOF
#!/usr/bin/env bash
# auto-generated stub: $cmd (exit=$exit_code) — НЕ редактировать, генерируется make-stub.sh
if [[ -n "\${STUB_LOG:-}" ]]; then
    mkdir -p "\$STUB_LOG"
    printf '%s\\n' "$cmd \$* [cwd=\$PWD]" >> "\$STUB_LOG/$cmd.log"
fi
if [[ -n "$stdout_text" ]]; then
    printf '%s\\n' '$stdout_text'
fi
exit $exit_code
EOF
chmod +x "$bin_dir/$cmd"
