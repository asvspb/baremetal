#!/usr/bin/env bats
load 'helpers'

# ==============================================================================
# L5: E2E dry-run против golden-эталона и подтверждение пользователя.
# Требует root (EUID-проверка deploy.sh); вне root — SKIP, не провал.
# ==============================================================================

@test "E-1: deploy.sh --full --dry-run -> exit 0, вывод = golden" {
    [[ $EUID -eq 0 ]] || skip "нужен root (sudo -n make test)"
    local out
    out="$(mktemp -d)/dry-out.txt"
    run timeout 300 bash "${REPO_DIR}/deploy.sh" --full --dry-run
    echo "$output" > "$out"
    assert_success
    # выравнивание построчно: без учёта времени (в выводе его нет)
    diff -u "${REPO_DIR}/tests/fixtures/dry-run-prep.golden" "$out"
    rm -rf "$(dirname "$out")"
}

@test "E-2: подтверждение «н» без --dry-run -> abort, мутирующих вызовов нет" {
    [[ $EUID -eq 0 ]] || skip "нужен root (sudo -n make test)"
    local log bin
    log="$(mktemp -d)/stublog"; bin="$(mktemp -d)/bin"
    mkdir -p "$log" "$bin"
    cp "${REPO_DIR}/tests/stubs/custom/"* "$bin/"; chmod +x "$bin/"*
    local cmd
    for cmd in parted mkfs.fat mkfs.ntfs mkfs.exfat mkfs.vfat mkfs.ext4 mkfs.f2fs \
               mkswap partprobe e2fsck resize2fs sleep fallocate umount swapoff \
               swapon blkid dosfsck; do
        STUB_BIN="$bin" bash "${REPO_DIR}/tests/stubs/make-stub.sh" "$cmd" 0
    done
    STUB_BIN="$bin" bash "${REPO_DIR}/tests/stubs/make-stub.sh" dd 1
    STUB_BIN="$bin" bash "${REPO_DIR}/tests/stubs/make-stub.sh" mount 0

    local rc=0
    STUB_LOG="$log" PATH="$bin:$PATH" \
        timeout 120 bash "${REPO_DIR}/deploy.sh" --full </dev/null >/dev/null 2>&1 || rc=$?
    # stdin /dev/null: read получает EOF -> пустой ответ -> die «Операция отменена»
    assert_equal "$rc" "1"
    # мутирующие команды ни разу не вызывались
    local f
    for f in parted mkfs.fat mkfs.ntfs mkfs.exfat mkfs.ext4 mkswap dd; do
        [[ ! -e "$log/$f.log" ]]
    done
    rm -rf "$(dirname "$log")" "$(dirname "$bin")"
}

@test "S-H3 (conditional): split-home.sh --dry-run -> exit 0" {
    [[ $EUID -eq 0 ]] || skip "нужен root"
    [[ -b /dev/nvme0n1p7 ]] || skip "на этой машине нет /dev/nvme0n1p7 с целевой разметкой"
    run timeout 300 bash "${REPO_DIR}/split-home.sh" --dry-run
    assert_success
}
