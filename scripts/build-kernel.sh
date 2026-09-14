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
                       [--gpg-keyring FILE] [--signing-key FILE]
                       [--signing-cert FILE] [--prepare-only]

Builds pinned Linux ${KERNEL_VERSION} using upstream bindeb-pkg. The SHA-256 is
always verified. If --gpg-keyring is supplied, the detached kernel.org signature
over the uncompressed tar archive is also required to verify. Full builds require
a PEM private key and matching X.509 certificate to sign every packaged image.
EOF
}

sign_image_package() {
    local package=$1 work_root=$2 sequence=$3
    local package_root="${work_root}/package-${sequence}"
    local rebuilt="${package}.signed"
    local image signed_image
    local images=()

    dpkg-deb --raw-extract "${package}" "${package_root}"
    mapfile -d '' -t images < <(
        find "${package_root}/boot" -maxdepth 1 -type f -name 'vmlinuz-*' -print0
    )
    (( ${#images[@]} > 0 )) || die "kernel image package contains no bootable image: ${package}"
    for image in "${images[@]}"; do
        signed_image="${image}.signed"
        sbsign --key "${signing_key}" --cert "${signing_cert}" \
            --output "${signed_image}" "${image}"
        sbverify --cert "${signing_cert}" "${signed_image}" >/dev/null
        chmod --reference="${image}" "${signed_image}"
        mv -- "${signed_image}" "${image}"
    done
    if [[ -f ${package_root}/DEBIAN/md5sums ]]; then
        (cd "${package_root}" &&
            find . -path ./DEBIAN -prune -o -type f -printf '%P\0' |
            sort -z | xargs -0 md5sum) >"${package_root}/DEBIAN/md5sums"
        chmod 0644 "${package_root}/DEBIAN/md5sums"
    fi
    dpkg-deb --root-owner-group --build "${package_root}" "${rebuilt}"
    mv -- "${rebuilt}" "${package}"
}

build_root="${PROJECT_ROOT}/build/kernel-${KERNEL_VERSION}"
base_config="/boot/config-$(uname -r)"
jobs="$(nproc)"
gpg_keyring=""
signing_key=""
signing_cert=""
prepare_only=false
while (($#)); do
    case "$1" in
        --build-root) [[ $# -ge 2 ]] || die "--build-root needs a path"; build_root=$2; shift 2 ;;
        --config) [[ $# -ge 2 ]] || die "--config needs a file"; base_config=$2; shift 2 ;;
        --jobs) [[ $# -ge 2 ]] || die "--jobs needs a count"; jobs=$2; shift 2 ;;
        --gpg-keyring) [[ $# -ge 2 ]] || die "--gpg-keyring needs a file"; gpg_keyring=$2; shift 2 ;;
        --signing-key) [[ $# -ge 2 ]] || die "--signing-key needs a file"; signing_key=$2; shift 2 ;;
        --signing-cert) [[ $# -ge 2 ]] || die "--signing-cert needs a file"; signing_cert=$2; shift 2 ;;
        --prepare-only) prepare_only=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

require_jammy
[[ -r ${base_config} ]] || die "baseline config is not readable: ${base_config}"
[[ ${jobs} =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"
for tool in awk bc bison curl dpkg-buildpackage dpkg-deb fakeroot flex gcc make openssl \
    pkg-config rsync sha256sum tar xz; do
    have "${tool}" || die "missing build tool: ${tool}; run install-build-deps.sh"
done
if ! ${prepare_only}; then
    [[ -r ${signing_key} ]] || die "full builds require a readable --signing-key"
    [[ -r ${signing_cert} ]] || die "full builds require a readable PEM --signing-cert"
    for tool in md5sum sbsign sbverify; do
        have "${tool}" || die "missing signing tool: ${tool}; run install-build-deps.sh"
    done
    openssl x509 -in "${signing_cert}" -noout >/dev/null 2>&1 ||
        die "--signing-cert must be a PEM X.509 certificate"
    x509_subject_key_id "${signing_cert}" >/dev/null
fi

mkdir -p "${build_root}/downloads" "${build_root}/source" "${build_root}/packages"
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

extract_root="$(mktemp -d -- "${build_root}/source/.linux-${KERNEL_VERSION}.XXXXXX")"
trap 'rm -rf -- "${extract_root}"' EXIT
tar -C "${extract_root}" -xf "${tarball}"
fresh_source="${extract_root}/linux-${KERNEL_VERSION}"
[[ -f ${fresh_source}/Makefile ]] || die "verified kernel archive did not contain the expected source tree"
rm -rf -- "${source_dir}"
mv -- "${fresh_source}" "${source_dir}"
rm -rf -- "${extract_root}"
trap - EXIT

# The source archive is authoritative only if no objects from an earlier build
# can be reused against it. Recreate O= from scratch on every invocation.
rm -rf -- "${build_root}/obj"
mkdir -- "${build_root}/obj"

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

find "${build_root}/packages" -maxdepth 1 -type f \
    \( -name '*.deb' -o -name '*.changes' -o -name '*.buildinfo' -o -name 'SHA256SUMS' \) \
    -delete
find "${build_root}" -maxdepth 2 -type f \
    -name '*.deb' \
    ! -path "${build_root}/packages/*" \
    -exec cp -f {} "${build_root}/packages/" \;
mapfile -t built_debs < <(
    find "${build_root}/packages" -maxdepth 1 -type f -name '*.deb' -printf '%f\n' | sort
)
(( ${#built_debs[@]} > 0 )) || die "kernel build produced no Debian packages"
signing_root="$(mktemp -d -- "${build_root}/.package-signing.XXXXXX")"
trap 'rm -rf -- "${signing_root}"' EXIT
signed_images=0
package_sequence=0
for built_deb in "${built_debs[@]}"; do
    package_path="${build_root}/packages/${built_deb}"
    package_name="$(dpkg-deb -f "${package_path}" Package)"
    if [[ ${package_name} == linux-image-*-jammy-modern ]]; then
        package_sequence=$((package_sequence + 1))
        sign_image_package "${package_path}" "${signing_root}" "${package_sequence}"
        signed_images=$((signed_images + 1))
    fi
done
(( signed_images > 0 )) || die "kernel build produced no image package to sign"
rm -rf -- "${signing_root}"
trap - EXIT
(cd "${build_root}/packages" && sha256sum -- "${built_debs[@]}" >SHA256SUMS)
manifest_digest="$(sha256sum "${build_root}/packages/SHA256SUMS")"
manifest_digest="${manifest_digest%% *}"
log "packages and manifest: ${build_root}/packages"
log "trusted manifest SHA-256 (pass with --manifest-sha256): ${manifest_digest}"
