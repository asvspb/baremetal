#!/usr/bin/env bash
# I-M7: интерактивная настройка разделов через piped-ввод
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scenario_init usb
# shellcheck disable=SC1091
source "${REPO_DIR}/make-boot-usb.sh" >/dev/null 2>&1
export STUB_DF_TYPE="ext4"
TARGET_DISK="/dev/fakedisk"
out=$(printf '8\n1\n\n\n' | { configure_partitions 2>&1; echo "VARS DATA_FS=$DATA_FS VENTOY_SIZE_G=$VENTOY_SIZE_G LABEL_P1=$LABEL_P1 LABEL_P3=$LABEL_P3"; }) || true
echo "$out" | grep -q 'Конфигурация' && echo "HAS-CONFIG-LINE"
echo "$out" | grep '^VARS ' | head -n 1
scenario_cleanup
