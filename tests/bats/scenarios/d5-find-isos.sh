#!/usr/bin/env bash
# U-D5: find_isos находит фикстурные ISO в SCRIPT_DIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scenario_init deploy
# shellcheck disable=SC1091
source "${REPO_DIR}/deploy.sh" >/dev/null 2>&1
fx="${SCEN_TMP}/isos"
/bin/mkdir -p "$fx"
truncate -s 1M "$fx/fake-win.iso"
truncate -s 1M "$fx/fake-ubuntu.iso"
SCRIPT_DIR="$fx" find_isos
echo "WIN=${WIN_ISO##*/}"
echo "UBU=${UBUNTU_ISO##*/}"
scenario_cleanup
