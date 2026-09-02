#!/usr/bin/env bash
# I-D1: PREP_DISK на заглушках — последовательность parted/mkfs и autounattend.
# Целевое устройство — /dev/fakenvme0n1 (НЕ существует); проверка безопасности:
# все вызовы parted/mkfs обязаны ссылаться только на fakenvme0n1.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scenario_init deploy
# shellcheck disable=SC1091
source "${REPO_DIR}/deploy.sh" >/dev/null 2>&1
# shellcheck disable=SC1091
source "${REPO_DIR}/deploy.conf"   # размеры разделов — как в реальном запуске
TARGET_DISK="/dev/fakenvme0n1"
DRY=0
WIN_ISO=""
ORIG_SCRIPT_DIR="${SCEN_TMP}"
SCRIPT_DIR="${REPO_DIR}"
TIMEZONE="${TIMEZONE:-Europe/Moscow}"

do_prep_disk >/dev/null 2>&1
rc=$?
echo "RC=$rc"

# --- безопасность: только фейковое устройство ---
bad=$(grep -hE '/dev/(nvme|sd|vd|hd|mmcblk)' "$STUB_LOG"/*.log 2>/dev/null | grep -v fakenvme0n1 || true)
if [[ -n "$bad" ]]; then
    echo "SAFETY-FAIL: вызовы с реальными устройствами: $bad"
    scenario_cleanup
    exit 0
fi

p_log="${STUB_LOG}/parted.log"
[[ -f "$p_log" ]] || { echo "FAIL: parted не вызывался"; scenario_cleanup; exit 0; }

# --- MiB-арифметика из conf ---
a=$((1)); b=$((1+EFI_SIZE_MB)); c=$((b+MSR_SIZE_MB))
d=$((c+WINDOWS_SIZE_GB*1024)); e=$((d+RECOVERY_SIZE_MB))
f=$((e+SHARED_SIZE_GB*1024)); g=$((f+UBUNTU_ROOT_SIZE_GB*1024))

check() { # $1 ожидаемый фрагмент
    if ! grep -Fq "$1" "$p_log"; then echo "FAIL: нет в parted.log: $1"; rc=1; fi
}
check "mklabel gpt"
check "mkpart EFI fat32 ${a}MiB ${b}MiB"
check "mkpart Microsoft reserved partition ${b}MiB ${c}MiB"
check "mkpart Windows ntfs ${c}MiB ${d}MiB"
check "mkpart Recovery ntfs ${d}MiB ${e}MiB"
check "mkpart SHARED ${e}MiB ${f}MiB"
check "mkpart UbuntuRoot ext4 ${f}MiB ${g}MiB"
check "mkpart UbuntuHome ext4 ${g}MiB 100%"
check "set 1 boot on"
check "set 1 esp on"
check "set 2 msftres on"
check "set 3 msftdata on"
check "set 4 hidden on"
check "set 4 diag on"
check "set 5 msftdata on"
n_mkpart=$(grep -c 'mkpart' "$p_log")
[[ "$n_mkpart" == "7" ]] || { echo "FAIL: mkpart $n_mkpart раз (ожидалось 7)"; rc=1; }

# --- mkfs: устройства (p-суффикс через part_dev) и метки ---
grep -Fq 'mkfs.fat -F32 -n EFI /dev/fakenvme0n1p1' "${STUB_LOG}/mkfs.fat.log" 2>/dev/null || { echo "FAIL: mkfs.fat EFI p1"; rc=1; }
grep -Fq 'mkfs.ntfs -f -L Windows /dev/fakenvme0n1p3' "${STUB_LOG}/mkfs.ntfs.log" 2>/dev/null || { echo "FAIL: mkfs.ntfs Windows p3"; rc=1; }
grep -Fq 'mkfs.ntfs -f -L Recovery /dev/fakenvme0n1p4' "${STUB_LOG}/mkfs.ntfs.log" 2>/dev/null || { echo "FAIL: mkfs.ntfs Recovery p4"; rc=1; }
if [[ "${SHARED_FSTYPE:-exfat}" == "exfat" ]]; then
    grep -Fq 'mkfs.exfat -L SHARED /dev/fakenvme0n1p5' "${STUB_LOG}/mkfs.exfat.log" 2>/dev/null || { echo "FAIL: mkfs.exfat SHARED p5"; rc=1; }
fi
grep -Fq 'mkfs.ext4 -F -L UbuntuRoot /dev/fakenvme0n1p6' "${STUB_LOG}/mkfs.ext4.log" 2>/dev/null || { echo "FAIL: mkfs.ext4 Root p6"; rc=1; }
grep -Fq 'mkfs.ext4 -F -L UbuntuHome /dev/fakenvme0n1p7' "${STUB_LOG}/mkfs.ext4.log" 2>/dev/null || { echo "FAIL: mkfs.ext4 Home p7"; rc=1; }

# --- autounattend.xml создан и валиден ---
xml="${SCEN_TMP}/autounattend.xml"
[[ -f "$xml" ]] || { echo "FAIL: autounattend.xml не создан"; rc=1; }
grep -Eq '__[A-Z_]+__' "$xml" 2>/dev/null && { echo "FAIL: остались плейсхолдеры"; rc=1; }
if [[ -f "$xml" ]] && command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$xml" 2>/dev/null || { echo "FAIL: xmllint отклонил XML"; rc=1; }
fi

(( rc == 0 )) && echo "OK: последовательность PREP_DISK корректна"
scenario_cleanup
