#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

usage() {
    printf 'Usage: %s --from DIR --manifest-sha256 SHA256 [--trusted-cert CERT.der] [--apply]\n' "$0"
}

package_dir=""
manifest_sha256=""
trusted_cert=""
apply=false
while (($#)); do
    case "$1" in
        --from) [[ $# -ge 2 ]] || die "--from needs a directory"; package_dir=$2; shift 2 ;;
        --manifest-sha256) [[ $# -ge 2 ]] || die "--manifest-sha256 needs a digest"; manifest_sha256=$2; shift 2 ;;
        --trusted-cert) [[ $# -ge 2 ]] || die "--trusted-cert needs a certificate"; trusted_cert=$2; shift 2 ;;
        --apply) apply=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

require_jammy
check_ubuntu_sources_are_jammy --
[[ -d ${package_dir} ]] || die "package directory not found: ${package_dir:-<unset>}"
[[ ${manifest_sha256} =~ ^[[:xdigit:]]{64}$ ]] ||
    die "--manifest-sha256 must be the trusted 64-character digest printed by build-kernel.sh"
manifest="${package_dir}/SHA256SUMS"
[[ -f ${manifest} && ! -L ${manifest} ]] || die "trusted package manifest is missing or unsafe: ${manifest}"
actual_manifest_sha256="$(sha256sum "${manifest}")"
actual_manifest_sha256="${actual_manifest_sha256%% *}"
[[ ${actual_manifest_sha256} == "${manifest_sha256,,}" ]] || die "kernel package manifest digest mismatch"

declare -A manifested_debs=()
while IFS=' ' read -r package_sha256 manifest_name manifest_extra; do
    manifest_name="${manifest_name#\*}"
    [[ ${package_sha256} =~ ^[[:xdigit:]]{64}$ && -n ${manifest_name} && -z ${manifest_extra} ]] ||
        die "malformed kernel package manifest entry"
    [[ ${manifest_name} != */* && ${manifest_name} == *.deb ]] ||
        die "unsafe kernel package manifest path: ${manifest_name}"
    [[ -z ${manifested_debs["${manifest_name}"]:-} ]] ||
        die "duplicate kernel package manifest entry: ${manifest_name}"
    [[ -f ${package_dir}/${manifest_name} && ! -L ${package_dir}/${manifest_name} ]] ||
        die "manifested kernel package is missing or unsafe: ${manifest_name}"
    manifested_debs["${manifest_name}"]="${package_sha256,,}"
done <"${manifest}"
(( ${#manifested_debs[@]} > 0 )) || die "kernel package manifest contains no packages"
(cd "${package_dir}" && sha256sum --check --strict --status SHA256SUMS) ||
    die "kernel package checksum verification failed"

packages=()
releases=()
image_packages=()
declare -A header_releases=()
while IFS= read -r deb; do
    deb_name="${deb##*/}"
    [[ -n ${manifested_debs["${deb_name}"]:-} ]] ||
        die "unmanifested kernel package found: ${deb_name}"
    package_name="$(dpkg-deb -f "${deb}" Package)"
    case "${package_name}" in
        linux-image-*-jammy-modern)
            packages+=("${deb}")
            image_packages+=("${deb}")
            releases+=("${package_name#linux-image-}")
            ;;
        linux-headers-*-jammy-modern)
            packages+=("${deb}")
            header_releases["${package_name#linux-headers-}"]=1
            ;;
    esac
done < <(find "${package_dir}" -maxdepth 1 -type f -name '*.deb' -print | sort)
(( ${#releases[@]} > 0 )) || die "no jammy-modern image packages found in ${package_dir}"
for release in "${releases[@]}"; do
    [[ ${header_releases["${release}"]:-} == 1 ]] ||
        die "matching headers package is missing for ${release}"
done

stock="$(stock_kernel_packages)"
[[ -n ${stock} ]] || die "no stock linux-image-*-generic package is installed; rollback invariant failed"
log "stock rollback kernels retained:\n${stock}"

secure_boot=false
trusted_cert_pem=""
if secure_boot_enabled; then
    secure_boot=true
    have sbverify || die "Secure Boot is enabled and sbverify is unavailable"
    [[ -r ${trusted_cert} ]] || die "Secure Boot requires a readable --trusted-cert in DER format"
    require_enrolled_mok "${trusted_cert}"
    temp_dir="$(mktemp -d)"
    trap 'rm -rf -- "${temp_dir}"' EXIT
    trusted_cert_pem="${temp_dir}/trusted-cert.pem"
    openssl x509 -inform DER -in "${trusted_cert}" -out "${trusted_cert_pem}"
    image_index=0
    for image_deb in "${image_packages[@]}"; do
        image_index=$((image_index + 1))
        extract_dir="${temp_dir}/image-${image_index}"
        mkdir "${extract_dir}"
        dpkg-deb -x "${image_deb}" "${extract_dir}"
        mapfile -d '' -t image_paths < <(
            find "${extract_dir}/boot" -maxdepth 1 -type f -name 'vmlinuz-*' -print0
        )
        (( ${#image_paths[@]} > 0 )) || die "kernel image package contains no bootable image: ${image_deb}"
        for image_path in "${image_paths[@]}"; do
            sbverify --cert "${trusted_cert_pem}" "${image_path}" >/dev/null ||
                die "kernel image is not signed by the enrolled trusted certificate: ${image_deb}"
        done
    done
fi

log "would install only these custom image/header packages:"
printf '  %s\n' "${packages[@]}" >&2
if confirm_apply "${apply}"; then
    require_root
    apt-get install --no-install-recommends "${packages[@]}"
    for release in "${releases[@]}"; do
        [[ -r /boot/vmlinuz-"${release}" ]] || die "installed kernel image is missing for ${release}"
        [[ -d /lib/modules/"${release}" ]] || die "installed module tree is missing for ${release}"
        if ${secure_boot}; then
            sbverify --cert "${trusted_cert_pem}" "/boot/vmlinuz-${release}" >/dev/null ||
                die "installed kernel image is not signed by the enrolled trusted certificate: ${release}"
        fi
        if have dkms; then
            dkms autoinstall -k "${release}"
        fi
    done
    update-initramfs -u -k all
    update-grub
    log "installation complete; do not change GRUB default until the stock-kernel fallback has been tested"
fi
