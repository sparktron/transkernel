#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

readonly FW_REPO="https://gitlab.com/kernel-firmware/linux-firmware.git"
readonly FW_TAG="20260810"
readonly FW_COMMIT="2135b2f7714a3a514c989b9728f51f36144cab6f"

usage() {
    cat <<EOF
Usage:
  install-firmware.sh audit
  install-firmware.sh fetch [--source DIR]
  install-firmware.sh build --selection FILE [--source DIR] [--output DIR]
  install-firmware.sh install --package FILE [--apply]

Upstream firmware is pinned to tag ${FW_TAG}, commit ${FW_COMMIT}. The build mode
packages only exact relative paths listed in the selection file under
/lib/firmware/updates. Blank lines and # comments are ignored; globs are rejected.
EOF
}

action=${1:-}
[[ -n ${action} ]] || { usage; exit 2; }
[[ ${action} == -h || ${action} == --help ]] && { usage; exit 0; }
shift
source_dir="${PROJECT_ROOT}/build/linux-firmware-${FW_TAG}"
selection=""
output_dir="${PROJECT_ROOT}/dist"
package=""
apply=false
while (($#)); do
    case "$1" in
        --source) [[ $# -ge 2 ]] || die "--source needs a path"; source_dir=$2; shift 2 ;;
        --selection) [[ $# -ge 2 ]] || die "--selection needs a file"; selection=$2; shift 2 ;;
        --output) [[ $# -ge 2 ]] || die "--output needs a directory"; output_dir=$2; shift 2 ;;
        --package) [[ $# -ge 2 ]] || die "--package needs a file"; package=$2; shift 2 ;;
        --apply) apply=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

case "${action}" in
    audit)
        log "loaded and missing firmware evidence from current boot"
        journalctl -k -b --no-pager 2>/dev/null |
            grep -Eai 'firmware|Direct firmware load|iwlwifi|bluetooth|sof|drm|xe|i915' || true
        printf '\nFirmware requested by key modules (not proof that each blob is used):\n'
        for module in xe i915 iwlwifi btintel snd_sof_pci_intel_ptl nvidia; do
            modinfo -F firmware "${module}" 2>/dev/null | sed "s|^|${module}: |" || true
        done
        ;;
    fetch)
        have git || die "git is required"
        if [[ ! -d ${source_dir}/.git ]]; then
            mkdir -p "$(dirname "${source_dir}")"
            git clone --filter=blob:none --no-checkout "${FW_REPO}" "${source_dir}"
        fi
        git -C "${source_dir}" fetch --depth 1 origin "refs/tags/${FW_TAG}:refs/tags/${FW_TAG}"
        git -C "${source_dir}" checkout --detach "${FW_COMMIT}"
        actual="$(git -C "${source_dir}" rev-parse HEAD)"
        [[ ${actual} == "${FW_COMMIT}" ]] || die "firmware commit mismatch: ${actual}"
        if git -C "${source_dir}" cat-file -t "${FW_TAG}" 2>/dev/null | grep -qx tag; then
            git -C "${source_dir}" verify-tag "${FW_TAG}" ||
                log "WARNING: tag signature was not trusted by the local GPG keyring"
        fi
        log "firmware source ready at ${source_dir} (${actual})"
        ;;
    build)
        [[ -r ${selection} ]] || die "--selection must name a readable file"
        [[ -d ${source_dir}/.git ]] || die "run '$0 fetch' first or provide --source"
        actual="$(git -C "${source_dir}" rev-parse HEAD)"
        [[ ${actual} == "${FW_COMMIT}" ]] || die "source must be pinned commit ${FW_COMMIT}; found ${actual}"
        git_worktree_is_clean "${source_dir}" || die "firmware source has staged, unstaged, or untracked modifications"
        have dpkg-deb || die "dpkg-deb is required"
        stage="$(mktemp -d)"
        trap 'rm -rf -- "${stage}"' EXIT
        root="${stage}/package"
        mkdir -p "${root}/DEBIAN" "${root}/lib/firmware/updates" \
            "${root}/usr/share/doc/jammy-modern-firmware"
        count=0
        while IFS= read -r entry || [[ -n ${entry} ]]; do
            entry="${entry%%#*}"
            entry="${entry%"${entry##*[![:space:]]}"}"
            entry="${entry#"${entry%%[![:space:]]*}"}"
            [[ -n ${entry} ]] || continue
            [[ ${entry} != /* && ${entry} != *'..'* && ${entry} != *'*'* && ${entry} != *'?'* && ${entry} != *'['* ]] \
                || die "unsafe or non-literal selection entry: ${entry}"
            [[ -f ${source_dir}/${entry} || -L ${source_dir}/${entry} ]] \
                || die "selected firmware does not exist: ${entry}"
            mkdir -p "${root}/lib/firmware/updates/$(dirname "${entry}")"
            cp -L --preserve=mode,timestamps "${source_dir}/${entry}" "${root}/lib/firmware/updates/${entry}"
            count=$((count + 1))
        done <"${selection}"
        (( count > 0 )) || die "selection contains no firmware paths"
        cp "${source_dir}/WHENCE" "${root}/usr/share/doc/jammy-modern-firmware/WHENCE"
        find "${source_dir}" -maxdepth 1 -type f \( -name 'LICENCE*' -o -name 'LICENSE*' \) \
            -exec cp {} "${root}/usr/share/doc/jammy-modern-firmware/" \;
        if [[ -d ${source_dir}/LICENSES ]]; then
            cp -a "${source_dir}/LICENSES" "${root}/usr/share/doc/jammy-modern-firmware/"
        fi
        cp "${selection}" "${root}/usr/share/doc/jammy-modern-firmware/selection.txt"
        printf '%s\n' "${FW_COMMIT}" >"${root}/usr/share/doc/jammy-modern-firmware/source-commit"
        (cd "${root}/lib/firmware/updates" && find . -type f -print0 | sort -z | xargs -0 sha256sum) \
            >"${root}/usr/share/doc/jammy-modern-firmware/SHA256SUMS"
        installed_size="$(du -sk "${root}" | awk '{print $1}')"
        cat >"${root}/DEBIAN/control" <<EOF
Package: jammy-modern-firmware
Version: ${FW_TAG}-1
Section: non-free/kernel
Priority: optional
Architecture: all
Installed-Size: ${installed_size}
Maintainer: Local Administrator <root@localhost>
Depends: linux-firmware
Description: selected upstream firmware overlay for Jammy modern hardware
 Exact files from linux-firmware ${FW_COMMIT}; see packaged manifest and hashes.
EOF
        cat >"${root}/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
command -v update-initramfs >/dev/null 2>&1 && update-initramfs -u -k all
exit 0
EOF
        cat >"${root}/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
command -v update-initramfs >/dev/null 2>&1 && update-initramfs -u -k all
exit 0
EOF
        chmod 0755 "${root}/DEBIAN/postinst" "${root}/DEBIAN/postrm"
        mkdir -p "${output_dir}"
        out="${output_dir}/jammy-modern-firmware_${FW_TAG}-1_all.deb"
        dpkg-deb --root-owner-group --build "${root}" "${out}"
        (cd "$(dirname "${out}")" && sha256sum "$(basename "${out}")") >"${out}.sha256"
        log "built ${out} with ${count} explicitly selected entries"
        ;;
    install)
        require_jammy
        check_ubuntu_sources_are_jammy --
        [[ -r ${package} ]] || die "--package must name a readable .deb"
        checksum="${package}.sha256"
        [[ -r ${checksum} ]] || die "firmware checksum is missing: ${checksum}"
        have sha256sum || die "sha256sum is required to verify the firmware package"
        IFS=' ' read -r expected_checksum checksum_name checksum_extra <"${checksum}" ||
            die "firmware checksum is unreadable: ${checksum}"
        checksum_name="${checksum_name#\*}"
        [[ ${expected_checksum} =~ ^[[:xdigit:]]{64}$ && -n ${checksum_name} && -z ${checksum_extra} ]] ||
            die "firmware checksum is malformed: ${checksum}"
        [[ ${checksum_name##*/} == "${package##*/}" ]] ||
            die "firmware checksum names a different package: ${checksum_name}"
        actual_checksum="$(sha256sum "${package}")"
        actual_checksum="${actual_checksum%% *}"
        [[ ${actual_checksum} == "${expected_checksum,,}" ]] ||
            die "firmware package checksum verification failed: ${package}"
        [[ $(dpkg-deb -f "${package}" Package) == jammy-modern-firmware ]] \
            || die "package is not jammy-modern-firmware"
        log "would install firmware overlay: ${package}"
        dpkg-deb -c "${package}"
        if confirm_apply "${apply}"; then
            require_root
            apt-get install --no-install-recommends "${package}"
            update-initramfs -u -k all
            log "cold boot, validate, and retain this .deb for provenance"
        fi
        ;;
    *) usage; die "unknown action: ${action}" ;;
esac
