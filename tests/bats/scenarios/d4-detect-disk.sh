#!/usr/bin/env bash
# U-D4: detect_disk AUTO с udevadm-заглушкой.
# Варианты: all-usb (всё USB -> fallback nvme), none-usb (первый существующий),
# usb-only-nvme (nvme = usb, sda = не usb -> выбор sda; требует /dev/sda).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scenario_init deploy
# shellcheck disable=SC1091
source "${REPO_DIR}/deploy.sh" >/dev/null 2>&1
variant="$1"
case "$variant" in
    all-usb)
        export STUB_UDEVADM_USB_DEVICES="nvme0n1,sda,vda"
        [[ -b /dev/nvme0n1 ]] || { echo "SKIP: нет /dev/nvme0n1"; scenario_cleanup; exit 0; }
        TARGET_DISK="AUTO"
        detect_disk
        echo "TARGET=$TARGET_DISK" ;;
    none-usb)
        export STUB_UDEVADM_USB_DEVICES=""
        [[ -b /dev/nvme0n1 ]] || { echo "SKIP: нет /dev/nvme0n1"; scenario_cleanup; exit 0; }
        TARGET_DISK="AUTO"
        detect_disk
        echo "TARGET=$TARGET_DISK" ;;
    usb-only-nvme)
        [[ -b /dev/sda ]] || { echo "SKIP: нет /dev/sda"; scenario_cleanup; exit 0; }
        export STUB_UDEVADM_USB_DEVICES="nvme0n1"
        TARGET_DISK="AUTO"
        detect_disk
        echo "TARGET=$TARGET_DISK" ;;
    *) echo "RC=2"; echo "unknown variant" ;;
esac
scenario_cleanup
