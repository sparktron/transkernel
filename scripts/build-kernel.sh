#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

readonly KERNEL_VERSION="7.0.14"
readonly KERNEL_SHA256="de9999b784d2293f00d39c62d8f92a08ab8a54bc4e80ffd250a0c09cb07a0f98"
readonly KERNEL_BASE_URL="https://cdn.kernel.org/pub/linux/kernel/v7.x"
readonly LOCALVERSION="-jammy-modern"

usage() {
    cat <<EOF
Usage: build-kernel.sh [--build-root DIR] [--config FILE] [--jobs N]
                       [--gpg-keyring FILE] [--prepare-only]

Builds pinned Linux ${KERNEL_VERSION} using upstream bindeb-pkg. The SHA-256 is
always verified. If --gpg-keyring is supplied, the detached kernel.org signature
over the uncompressed tar archive is also required to verify.
EOF
}

build_root="${PROJECT_ROOT}/build/kernel-${KERNEL_VERSION}"
base_config="/boot/config-$(uname -r)"
jobs="$(nproc)"
gpg_keyring=""
prepare_only=false
while (($#)); do
    case "$1" in
        --build-root) [[ $# -ge 2 ]] || die "--build-root needs a path"; build_root=$2; shift 2 ;;
        --config) [[ $# -ge 2 ]] || die "--config needs a file"; base_config=$2; shift 2 ;;
        --jobs) [[ $# -ge 2 ]] || die "--jobs needs a count"; jobs=$2; shift 2 ;;
        --gpg-keyring) [[ $# -ge 2 ]] || die "--gpg-keyring needs a file"; gpg_keyring=$2; shift 2 ;;
        --prepare-only) prepare_only=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

require_jammy
[[ -r ${base_config} ]] || die "baseline config is not readable: ${base_config}"
[[ ${jobs} =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"
for tool in awk bc bison curl dpkg-buildpackage fakeroot flex gcc make openssl \
    pkg-config rsync sha256sum tar xz; do
    have "${tool}" || die "missing build tool: ${tool}; run install-build-deps.sh"
done

mkdir -p "${build_root}/downloads" "${build_root}/source" "${build_root}/obj" "${build_root}/packages"
tarball="${build_root}/downloads/linux-${KERNEL_VERSION}.tar.xz"
signature="${build_root}/downloads/linux-${KERNEL_VERSION}.tar.sign"
source_dir="${build_root}/source/linux-${KERNEL_VERSION}"

if [[ ! -f ${tarball} ]]; then
    curl --fail --location --proto '=https' --tlsv1.2 \
        --output "${tarball}.partial" "${KERNEL_BASE_URL}/linux-${KERNEL_VERSION}.tar.xz"
    mv "${tarball}.partial" "${tarball}"
fi
printf '%s  %s\n' "${KERNEL_SHA256}" "${tarball}" | sha256sum --check --status \
    || die "kernel source checksum mismatch"

if [[ -n ${gpg_keyring} ]]; then
    [[ -r ${gpg_keyring} ]] || die "GPG keyring is not readable: ${gpg_keyring}"
    curl --fail --location --proto '=https' --tlsv1.2 \
        --output "${signature}" "${KERNEL_BASE_URL}/linux-${KERNEL_VERSION}.tar.sign"
    gpgv --keyring "${gpg_keyring}" "${signature}" <(xz --decompress --stdout "${tarball}") \
        || die "kernel.org signature verification failed"
else
    log "signature verification skipped: supply a trusted kernel.org maintainer keyring with --gpg-keyring"
fi

if [[ ! -f ${source_dir}/Makefile ]]; then
    tar -C "${build_root}/source" -xf "${tarball}"
fi

cp "${base_config}" "${build_root}/obj/.config"
"${source_dir}/scripts/kconfig/merge_config.sh" -m -O "${build_root}/obj" \
    "${build_root}/obj/.config" "${PROJECT_ROOT}/kernel/config/modern-hwe.config"

# Ubuntu configs refer to Canonical certificate files absent from upstream source.
"${source_dir}/scripts/config" --file "${build_root}/obj/.config" --set-str SYSTEM_TRUSTED_KEYS ""
"${source_dir}/scripts/config" --file "${build_root}/obj/.config" --set-str SYSTEM_REVOCATION_KEYS ""
"${source_dir}/scripts/config" --file "${build_root}/obj/.config" --set-str LOCALVERSION "${LOCALVERSION}"
"${source_dir}/scripts/config" --file "${build_root}/obj/.config" --disable LOCALVERSION_AUTO
make -C "${source_dir}" O="${build_root}/obj" olddefconfig

while read -r option allowed; do
    [[ -n ${option} && ${option} != \#* ]] || continue
    actual="$(sed -n "s/^${option}=//p" "${build_root}/obj/.config")"
    [[ ,${allowed}, == *,${actual},* ]] ||
        die "required config ${option} must be one of [${allowed}], found '${actual:-unset}'"
done <"${PROJECT_ROOT}/kernel/config/required-options.txt"

cp "${build_root}/obj/.config" "${build_root}/config-${KERNEL_VERSION}${LOCALVERSION}"
"${source_dir}/scripts/diffconfig" "${base_config}" "${build_root}/obj/.config" \
    >"${build_root}/config-delta.txt" 2>/dev/null || true

if ${prepare_only}; then
    log "prepared source and config in ${build_root}; inspect config-delta.txt"
    exit 0
fi

make -C "${source_dir}" O="${build_root}/obj" -j"${jobs}" bindeb-pkg \
    KDEB_PKGVERSION="${KERNEL_VERSION}-1jammy1" LOCALVERSION="${LOCALVERSION}"

find "${build_root}" -maxdepth 2 -type f \
    \( -name '*.deb' -o -name '*.changes' -o -name '*.buildinfo' \) \
    ! -path "${build_root}/packages/*" \
    -exec cp -n {} "${build_root}/packages/" \;
(cd "${build_root}/packages" && sha256sum ./*.deb >SHA256SUMS)
log "packages and manifest: ${build_root}/packages"
