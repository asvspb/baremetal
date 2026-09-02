#!/usr/bin/env bash
# I-D2: enable_os_prober — GRUB_DISABLE_OS_PROBER=false дописан (реальный sed)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scenario_init deploy
# shellcheck disable=SC1091
source "${REPO_DIR}/deploy.sh" >/dev/null 2>&1
etc="${SCEN_TMP}/etc/default"
/bin/mkdir -p "$etc"
printf 'GRUB_TIMEOUT=5\n#GRUB_DISABLE_OS_PROBER=true\nGRUB_DISABLE_OS_PROBER=true\nGRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n' > "$etc/grub"
enable_os_prober "${SCEN_TMP}" >/dev/null 2>&1
rc=$?
n=$(grep -c '^GRUB_DISABLE_OS_PROBER=' "$etc/grub")
val=$(grep '^GRUB_DISABLE_OS_PROBER=' "$etc/grub")
echo "RC=$rc"
echo "COUNT=$n"
echo "VALUE=$val"
if [[ "$rc" == "0" && "$n" == "1" && "$val" == "GRUB_DISABLE_OS_PROBER=false" ]]; then
    echo "OK"
fi
scenario_cleanup
