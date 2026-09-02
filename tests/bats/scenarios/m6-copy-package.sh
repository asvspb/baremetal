#!/usr/bin/env bash
# I-M6: copy_deploy_package — пакет появляется на «разделе данных»
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scenario_init usb
# shellcheck disable=SC1091
source "${REPO_DIR}/make-boot-usb.sh" >/dev/null 2>&1
export STUB_UMOUNT_SAVE="${SCEN_TMP}/saved"
TARGET_DISK="/dev/fakedisk"
DATA_FS="none"
P1="/dev/fakedisk1"; P3="/dev/fakedisk3"
copy_deploy_package >/dev/null 2>&1
rc=$?
echo "RC=$rc"
pkg="${SCEN_TMP}/saved/mnt_pkg_$$/deploy-baremetal"
for f in deploy.sh deploy.conf split-home.sh templates/unattend.xml.template; do
    [[ -f "$pkg/$f" ]] && echo "HAS $f" || echo "MISSING $f"
done
scenario_cleanup
