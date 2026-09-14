#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

verify_nvidia_modules_for_kernel() {
    local target=$1 module module_path signer module_key
    local modules=(nvidia nvidia_modeset nvidia_drm nvidia_uvm)
    for module in "${modules[@]}"; do
        module_path="$(modinfo -k "${target}" -F filename "${module}" 2>/dev/null || true)"
        [[ -n ${module_path} && -f ${module_path} ]] ||
            die "NVIDIA module ${module} is missing for target kernel ${target}"
        if ${secure_boot}; then
            signer="$(modinfo -k "${target}" -F signer "${module}" 2>/dev/null || true)"
            module_key="$(modinfo -k "${target}" -F sig_key "${module}" 2>/dev/null || true)"
            module_key="$(printf '%s' "${module_key}" | tr -d '[:space:]:')"
            module_key=${module_key^^}
            [[ -n ${signer} && ${module_key} == "${expected_mok_key_id}" ]] ||
                die "NVIDIA module ${module} for ${target} is not signed by the enrolled MOK certificate"
        fi
    done
}

verify_running_nvidia_module() {
    local target=$1 disk_version loaded_version
    [[ ${target} == "$(uname -r)" ]] || return 1
    modprobe nvidia
    [[ -d /sys/module/nvidia ]] || die "NVIDIA module load did not create /sys/module/nvidia"
    disk_version="$(modinfo -k "${target}" -F version nvidia 2>/dev/null || true)"
    loaded_version="$(cat /sys/module/nvidia/version 2>/dev/null || true)"
    [[ -n ${disk_version} && ${loaded_version} == "${disk_version}" ]] ||
        die "loaded NVIDIA module does not match the installed module for ${target}; reboot and verify again"
}

package="${NVIDIA_PACKAGE:-nvidia-driver-580-open}"
apply=false
kernel_release=""
allow_vendor_repo=false
mok_cert=""
while (($#)); do
    case "$1" in
        --package) [[ $# -ge 2 ]] || die "--package needs a name"; package=$2; shift 2 ;;
        --kernel-release) [[ $# -ge 2 ]] || die "--kernel-release needs a value"; kernel_release=$2; shift 2 ;;
        --allow-vendor-repo) allow_vendor_repo=true; shift ;;
        --mok-cert) [[ $# -ge 2 ]] || die "--mok-cert needs a certificate"; mok_cert=$2; shift 2 ;;
        --apply) apply=true; shift ;;
        -h|--help) printf 'Usage: %s [--package nvidia-driver-NNN-open] [--kernel-release RELEASE] [--allow-vendor-repo] [--mok-cert CERT.der] [--apply]\n' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

require_jammy
if ${allow_vendor_repo}; then
    check_ubuntu_sources_are_jammy -- developer.download.nvidia.com
else
    check_ubuntu_sources_are_jammy --
fi
[[ ${package} =~ ^nvidia-driver-([0-9]+)-open$ ]] || die "only Ubuntu open-driver metapackages are accepted"
branch=${BASH_REMATCH[1]}
(( branch >= 580 )) || die "NVIDIA open driver branch must be 580 or newer"
lspci -Dnnd 10de: 2>/dev/null | grep -q . || die "no NVIDIA PCI device detected"

candidate="$(apt-cache policy "${package}" | awk '/Candidate:/{print $2}')"
[[ -n ${candidate} && ${candidate} != '(none)' ]] || die "${package} has no candidate in configured Jammy repositories"
ubuntu_candidate="$(apt-cache madison "${package}" | awk -F'|' \
    '$3 ~ /(archive\.ubuntu\.com|security\.ubuntu\.com|ports\.ubuntu\.com)/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}')"
if [[ ${allow_vendor_repo} == true ]]; then
    install_version=${candidate}
else
    [[ -n ${ubuntu_candidate} ]] || die "no Ubuntu Jammy archive build found; use --allow-vendor-repo only after documenting why"
    install_version=${ubuntu_candidate}
fi
install_spec="${package}=${install_version}"
installed_pkg="$(dpkg-query -W -f='${Package}\t${Version}\n' 'nvidia-driver-*-open' 2>/dev/null || true)"
current_module="$(modinfo -F version nvidia 2>/dev/null || true)"
log "GPU(s):"
lspci -nn | grep -i nvidia >&2 || true
log "installed open metapackage(s): ${installed_pkg:-none}"
log "loaded/available NVIDIA module version: ${current_module:-none}"
log "apt candidate: ${package}=${candidate}; selected version: ${install_spec}"

target_kernels=()
if [[ -n ${kernel_release} ]]; then
    target_kernels+=("${kernel_release}")
else
    for module_dir in /lib/modules/*-jammy-modern; do
        [[ -d ${module_dir}/build ]] && target_kernels+=("${module_dir##*/}")
    done
fi
(( ${#target_kernels[@]} > 0 )) || target_kernels+=("$(uname -r)")
for target in "${target_kernels[@]}"; do
    [[ -d /lib/modules/${target}/build ]] || die "headers/build link missing for target kernel ${target}"
done
log "DKMS target kernel(s): ${target_kernels[*]}"

secure_boot=false
expected_mok_key_id=""
if secure_boot_enabled; then
    secure_boot=true
    [[ -r ${mok_cert} ]] || die "Secure Boot requires a readable --mok-cert in DER format"
    require_enrolled_mok "${mok_cert}"
    expected_mok_key_id="$(x509_subject_key_id "${mok_cert}")"
fi

if [[ -n ${current_module} ]]; then
    current_branch=${current_module%%.*}
    if [[ ${current_branch} =~ ^[0-9]+$ ]] && (( current_branch > branch )); then
        die "refusing to downgrade NVIDIA ${current_branch} to ${branch}; choose the installed/newer open metapackage explicitly"
    fi
fi

log "would install ${package}; no packages will be purged"
apt-get --simulate install --no-install-recommends "${install_spec}"
if confirm_apply "${apply}"; then
    require_root
    mkdir -p /var/lib/jammy-modern-hwe
    dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Status}\n' '*nvidia*' 2>/dev/null \
        >"/var/lib/jammy-modern-hwe/nvidia-packages-before-$(date -u +%Y%m%dT%H%M%SZ).tsv" || true
    apt-get install --no-install-recommends "${install_spec}"
    pending_load_checks=()
    for target in "${target_kernels[@]}"; do
        dkms autoinstall -k "${target}"
        depmod -a "${target}"
        verify_nvidia_modules_for_kernel "${target}"
        if ! verify_running_nvidia_module "${target}"; then
            pending_load_checks+=("${target}")
        fi
    done
    dkms status
    if (( ${#pending_load_checks[@]} > 0 )); then
        die "NVIDIA signatures are valid, but load verification requires booting each target and rerunning with --kernel-release: ${pending_load_checks[*]}"
    fi
    log "NVIDIA module signatures and runtime load verified; continue with PRIME, display, and suspend tests"
fi
