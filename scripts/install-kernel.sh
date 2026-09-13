#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

usage() {
    printf 'Usage: %s --from DIR [--apply]\n' "$0"
}

package_dir=""
apply=false
while (($#)); do
    case "$1" in
        --from) [[ $# -ge 2 ]] || die "--from needs a directory"; package_dir=$2; shift 2 ;;
        --apply) apply=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

require_jammy
check_ubuntu_sources_are_jammy
[[ -d ${package_dir} ]] || die "package directory not found: ${package_dir:-<unset>}"
packages=()
releases=()
while IFS= read -r deb; do
    package_name="$(dpkg-deb -f "${deb}" Package)"
    case "${package_name}" in
        linux-image-*-jammy-modern)
            packages+=("${deb}")
            releases+=("${package_name#linux-image-}")
            ;;
        linux-headers-*-jammy-modern)
            packages+=("${deb}")
            ;;
    esac
done < <(find "${package_dir}" -maxdepth 1 -type f -name '*.deb' -print | sort)
(( ${#packages[@]} > 0 )) || die "no jammy-modern image/header packages found in ${package_dir}"

stock="$(stock_kernel_packages)"
[[ -n ${stock} ]] || die "no stock linux-image-*-generic package is installed; rollback invariant failed"
log "stock rollback kernels retained:\n${stock}"

if secure_boot_enabled; then
    have sbverify || die "Secure Boot is enabled and sbverify is unavailable"
    image_deb=""
    for deb in "${packages[@]}"; do
        [[ $(dpkg-deb -f "${deb}" Package) == linux-image-* ]] && { image_deb=${deb}; break; }
    done
    [[ -n ${image_deb} ]] || die "Secure Boot is enabled but no image package was found"
    temp_dir="$(mktemp -d)"
    trap 'rm -rf -- "${temp_dir}"' EXIT
    dpkg-deb -x "${image_deb}" "${temp_dir}"
    image_path="$(find "${temp_dir}/boot" -maxdepth 1 -type f -name 'vmlinuz-*' -print -quit)"
    if [[ -z ${image_path} ]] || ! sbverify --list "${image_path}" >/dev/null 2>&1; then
        die "Secure Boot is enabled and the packaged kernel has no verifiable PE signature; see docs/secure-boot.md"
    fi
fi

log "would install only these custom image/header packages:"
printf '  %s\n' "${packages[@]}" >&2
if confirm_apply "${apply}"; then
    require_root
    apt-get install --no-install-recommends "${packages[@]}"
    for release in "${releases[@]}"; do
        [[ -r /boot/vmlinuz-"${release}" ]] || die "installed kernel image is missing for ${release}"
        [[ -d /lib/modules/"${release}" ]] || die "installed module tree is missing for ${release}"
        if have dkms; then
            dkms autoinstall -k "${release}"
        fi
    done
    update-initramfs -u -k all
    update-grub
    log "installation complete; do not change GRUB default until the stock-kernel fallback has been tested"
fi
