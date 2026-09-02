#!/usr/bin/env bash
# U-D7: без ISO Ubuntu (не dry-run) — die с сообщением про debootstrap
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
scenario_init deploy
# shellcheck disable=SC1091
source "${REPO_DIR}/deploy.sh" >/dev/null 2>&1
DRY=0
UBUNTU_ISO=""
TARGET_DISK="/dev/fakedisk"
rc=0
out=$(do_deploy_ubuntu 2>&1) || rc=$?
echo "RC=$rc"
echo "$out"
scenario_assert_no_mutating || rc=9
[[ "$rc" == "9" ]] && echo "SAFETY-FAIL"
scenario_cleanup
exit "$rc"
