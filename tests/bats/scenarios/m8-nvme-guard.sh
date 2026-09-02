#!/usr/bin/env bash
# I-M8: защита от выбора nvme.
# а) статически: guard «ОШИБКА БЕЗОПАСНОСТИ» присутствует в select_usb_disk;
# б) динамически: lsblk-заглушка с nvme-диском (TRAN=usb) -> диск НЕ попадает
#    в список выбора (grep -v nvme), выбор невозможен.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if grep -q 'nvme0n1' "${REPO_DIR}/make-boot-usb.sh" && grep -q 'ОШИБКА БЕЗОПАСНОСТИ' "${REPO_DIR}/make-boot-usb.sh"; then
    echo "GUARD-STATIC=PRESENT"
else
    echo "GUARD-STATIC=ABSENT"
fi
scenario_init usb
# shellcheck disable=SC1091
source "${REPO_DIR}/make-boot-usb.sh" >/dev/null 2>&1
export STUB_LSBLK_DISKS="/dev/nvme0n1  1T FakeNVMe usb"
out=$(printf '1\n' | select_usb_disk 2>&1) || true
# nvme-строка отфильтрована: список пуст -> «накопители не найдены»
echo "$out" | grep -q 'не найдены' && echo "NVME-NOT-OFFERED"
scenario_cleanup
