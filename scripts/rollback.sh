#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage:
  rollback.sh plan
  rollback.sh kernel --release 7.0.14-jammy-modern [--apply]
  rollback.sh firmware [--apply]

This script never purges stock kernels or NVIDIA packages.
EOF
}

action=${1:-plan}
shift || true
release=""
apply=false
while (($#)); do
    case "$1" in
        --release) [[ $# -ge 2 ]] || die "--release needs a value"; release=$2; shift 2 ;;
        --apply) apply=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

require_jammy
case "${action}" in
    plan)
        printf 'running-kernel\t%s\n' "$(uname -r)"
        printf '\nstock rollback kernels:\n'
        stock_kernel_packages
        printf '\ncustom packages:\n'
        dpkg-query -W -f='${binary:Package}\t${Version}\n' 2>/dev/null |
            grep -E 'jammy-modern|^jammy-modern-firmware' || true
        printf '\nGRUB saved entry:\n'
        grub-editenv list 2>/dev/null || true
        ;;
    kernel)
        [[ ${release} =~ ^7\.0(\.[0-9]+)?-jammy-modern$ ]] \
            || die "release must be an exact 7.0.x-jammy-modern value"
        [[ $(uname -r) != "${release}" ]] || die "refusing to remove the running kernel"
        mapfile -t packages < <(dpkg-query -W -f='${binary:Package}\n' 2>/dev/null |
            grep -E "^linux-(image|headers)-.*${release}" || true)
        (( ${#packages[@]} > 0 )) || die "no installed packages found for ${release}"
        [[ -n $(stock_kernel_packages) ]] || die "no stock Ubuntu kernel package remains"
        log "would remove (not purge): ${packages[*]}"
        if confirm_apply "${apply}"; then
            require_root
            apt-get remove "${packages[@]}"
            update-initramfs -u -k all
            update-grub
        fi
        ;;
    firmware)
        if ! dpkg-query -W -f='${db:Status-Status}' jammy-modern-firmware 2>/dev/null | grep -qx installed; then
            die "jammy-modern-firmware is not installed"
        fi
        log "would remove firmware overlay package; Ubuntu linux-firmware remains installed"
        if confirm_apply "${apply}"; then
            require_root
            apt-get remove jammy-modern-firmware
            update-initramfs -u -k all
        fi
        ;;
    -h|--help) usage ;;
    *) usage; die "unknown action: ${action}" ;;
esac

