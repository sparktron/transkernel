#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

apply=false
if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    printf 'Usage: %s [--apply]\n' "$0"
    exit 0
fi
[[ ${1:-} == --apply ]] && apply=true
[[ $# -le 1 ]] || die "usage: $0 [--apply]"

require_jammy
check_ubuntu_sources_are_jammy --

packages=(
    bc binutils bison build-essential cpio curl debhelper dwarves fakeroot flex
    git gnupg kmod libelf-dev libncurses-dev libssl-dev lz4 openssl pahole
    pkg-config rsync sbsigntool xz-utils zstd
)

log "would install Jammy build dependencies: ${packages[*]}"
if confirm_apply "${apply}"; then
    require_root
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends "${packages[@]}"
fi
