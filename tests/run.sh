#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

while IFS= read -r script; do
    if ! head -n 3 "${script}" | grep -q 'set -euo pipefail'; then
        printf 'FAIL: strict mode missing near top of %s\n' "${script}" >&2
        failures=$((failures + 1))
    fi
    if ! bash -n "${script}"; then
        printf 'FAIL: bash syntax: %s\n' "${script}" >&2
        failures=$((failures + 1))
    fi
done < <(find "${ROOT}/scripts" "${ROOT}/tests" -type f -name '*.sh' | sort)

if command -v shellcheck >/dev/null 2>&1; then
    mapfile -t shell_files < <(find "${ROOT}/scripts" "${ROOT}/tests" -type f -name '*.sh' | sort)
    shellcheck -x "${shell_files[@]}" || failures=$((failures + 1))
else
    printf 'SKIP: shellcheck unavailable\n'
fi

"${ROOT}/scripts/audit-host.sh" --help >/dev/null
"${ROOT}/scripts/build-kernel.sh" --help >/dev/null
"${ROOT}/scripts/install-build-deps.sh" --help >/dev/null
"${ROOT}/scripts/install-firmware.sh" --help >/dev/null
"${ROOT}/scripts/install-kernel.sh" --help >/dev/null
"${ROOT}/scripts/install-microcode.sh" --help >/dev/null
"${ROOT}/scripts/install-nvidia.sh" --help >/dev/null
"${ROOT}/scripts/validate-system.sh" --help >/dev/null
"${ROOT}/scripts/rollback.sh" --help >/dev/null

# shellcheck source=scripts/lib/common.sh
. "${ROOT}/scripts/lib/common.sh"

if ! (have() { return 1; }; secure_boot_enabled >/dev/null 2>&1); then
    printf 'FAIL: missing mokutil must fail closed\n' >&2
    failures=$((failures + 1))
fi

test_tmp="$(mktemp -d)"
trap 'rm -rf -- "${test_tmp}"' EXIT
apt_root="${test_tmp}/apt"
mkdir -p "${apt_root}/sources.list.d"
printf 'deb [arch=amd64 signed-by=/usr/share/keyrings/ubuntu.gpg] http://archive.ubuntu.com/ubuntu jammy-updates main\n' \
    >"${apt_root}/sources.list"
if ! APT_SOURCES_ROOT="${apt_root}" check_ubuntu_sources_are_jammy --; then
    printf 'FAIL: Jammy pocket was rejected\n' >&2
    failures=$((failures + 1))
fi
printf 'deb http://archive.ubuntu.com/ubuntu future main\n' >"${apt_root}/sources.list"
if (APT_SOURCES_ROOT="${apt_root}" check_ubuntu_sources_are_jammy -- >/dev/null 2>&1); then
    printf 'FAIL: unknown Ubuntu suite was accepted\n' >&2
    failures=$((failures + 1))
fi
printf 'deb https://packages.example.invalid/ubuntu jammy main\n' >"${apt_root}/sources.list"
if (APT_SOURCES_ROOT="${apt_root}" check_ubuntu_sources_are_jammy -- >/dev/null 2>&1); then
    printf 'FAIL: unapproved binary repository was accepted\n' >&2
    failures=$((failures + 1))
fi
printf 'deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/ /\n' \
    >"${apt_root}/sources.list"
if ! APT_SOURCES_ROOT="${apt_root}" check_ubuntu_sources_are_jammy -- developer.download.nvidia.com; then
    printf 'FAIL: explicitly approved flat NVIDIA repository was rejected\n' >&2
    failures=$((failures + 1))
fi
printf 'deb http://archive.ubuntu.com/ubuntu jammy main\n' >"${apt_root}/sources.list"
printf 'Types: deb\nURIs:\n http://archive.ubuntu.com/ubuntu\nSuites:\n noble\nComponents: main\n' \
    >"${apt_root}/sources.list.d/folded.sources"
if (APT_SOURCES_ROOT="${apt_root}" check_ubuntu_sources_are_jammy -- >/dev/null 2>&1); then
    printf 'FAIL: folded non-Jammy Deb822 suite was accepted\n' >&2
    failures=$((failures + 1))
fi
printf 'Types: deb\nURIs:\n https://packages.example.invalid/ubuntu\nSuites: jammy\nComponents: main\n' \
    >"${apt_root}/sources.list.d/folded.sources"
if (APT_SOURCES_ROOT="${apt_root}" check_ubuntu_sources_are_jammy -- >/dev/null 2>&1); then
    printf 'FAIL: folded unapproved Deb822 URI was accepted\n' >&2
    failures=$((failures + 1))
fi
printf 'Types: deb\nURIs:\n http://archive.ubuntu.com/ubuntu\nSuites:\n jammy\n jammy-updates\nComponents: main\n' \
    >"${apt_root}/sources.list.d/folded.sources"
if ! APT_SOURCES_ROOT="${apt_root}" check_ubuntu_sources_are_jammy --; then
    printf 'FAIL: valid folded Jammy Deb822 source was rejected\n' >&2
    failures=$((failures + 1))
fi
rm -f "${apt_root}/sources.list.d/folded.sources"

if command -v openssl >/dev/null 2>&1; then
    cert_key="${test_tmp}/test-mok.key"
    cert_pem="${test_tmp}/test-mok.pem"
    cert_der="${test_tmp}/test-mok.der"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=transkernel-test \
        -addext subjectKeyIdentifier=hash -keyout "${cert_key}" -out "${cert_pem}" \
        >/dev/null 2>&1
    openssl x509 -in "${cert_pem}" -outform DER -out "${cert_der}"
    pem_key_id="$(x509_subject_key_id "${cert_pem}")"
    der_key_id="$(x509_subject_key_id "${cert_der}")"
    if [[ ! ${pem_key_id} =~ ^[[:xdigit:]]{40}$ || ${pem_key_id} != "${der_key_id}" ]]; then
        printf 'FAIL: X.509 subject key identifier parsing disagrees for PEM and DER\n' >&2
        failures=$((failures + 1))
    fi
    mokutil() { [[ ${1:-} == --test-key && ${2:-} == "${cert_der}" ]]; }
    if ! require_enrolled_mok "${cert_der}"; then
        printf 'FAIL: enrolled DER MOK certificate was rejected\n' >&2
        failures=$((failures + 1))
    fi
    if (require_enrolled_mok "${cert_pem}" >/dev/null 2>&1); then
        printf 'FAIL: PEM certificate was accepted where enrolled DER MOK was required\n' >&2
        failures=$((failures + 1))
    fi
    unset -f mokutil
else
    printf 'SKIP: openssl unavailable for certificate parser test\n'
fi

git_repo="${test_tmp}/git"
git init -q "${git_repo}"
printf 'tracked\n' >"${git_repo}/tracked"
git -C "${git_repo}" add tracked
git -C "${git_repo}" -c user.name=Test -c user.email=test@example.invalid commit -qm initial
if ! git_worktree_is_clean "${git_repo}"; then
    printf 'FAIL: clean Git worktree was reported dirty\n' >&2
    failures=$((failures + 1))
fi
printf 'untracked\n' >"${git_repo}/untracked"
if git_worktree_is_clean "${git_repo}"; then
    printf 'FAIL: untracked Git file was ignored\n' >&2
    failures=$((failures + 1))
fi
rm -f "${git_repo}/untracked"
printf 'staged\n' >>"${git_repo}/tracked"
git -C "${git_repo}" add tracked
if git_worktree_is_clean "${git_repo}"; then
    printf 'FAIL: staged Git change was ignored\n' >&2
    failures=$((failures + 1))
fi

if grep -Fq 'jammy-modern-fio.test' "${ROOT}/scripts/validate-system.sh" ||
   ! grep -Fq 'mktemp --tmpdir=' "${ROOT}/scripts/validate-system.sh" ||
   ! grep -Fq "trap 'rm -f --" "${ROOT}/scripts/validate-system.sh"; then
    printf 'FAIL: fio validation path is not uniquely allocated\n' >&2
    failures=$((failures + 1))
fi
if grep -Fq -- '-exec cp -n ' "${ROOT}/scripts/build-kernel.sh" ||
   ! grep -Fq -- '-exec cp -f ' "${ROOT}/scripts/build-kernel.sh"; then
    printf 'FAIL: rebuilt kernel packages are not replaced\n' >&2
    failures=$((failures + 1))
fi
if grep -Fq "if [[ ! -f \${source_dir}/Makefile ]]" "${ROOT}/scripts/build-kernel.sh" ||
   ! grep -Fq "extract_root=\"\$(mktemp -d --" "${ROOT}/scripts/build-kernel.sh"; then
    printf 'FAIL: kernel source is not freshly extracted for every build\n' >&2
    failures=$((failures + 1))
fi
if ! grep -Fq -- '--manifest-sha256' "${ROOT}/scripts/install-kernel.sh" ||
   ! grep -Fq 'sha256sum --check --strict --status SHA256SUMS' "${ROOT}/scripts/install-kernel.sh"; then
    printf 'FAIL: kernel package manifest is not bound and verified\n' >&2
    failures=$((failures + 1))
fi
if ! grep -Fq 'MICROCODE_STATE_FILE=' "${ROOT}/scripts/install-microcode.sh" ||
   ! grep -Fq -- '--expected-revision' "${ROOT}/scripts/install-microcode.sh"; then
    printf 'FAIL: microcode verification lacks recorded or explicit revision checks\n' >&2
    failures=$((failures + 1))
fi
if ! grep -Fq 'sbsign --key' "${ROOT}/scripts/build-kernel.sh" ||
   ! grep -Fq 'sbverify --cert' "${ROOT}/scripts/build-kernel.sh"; then
    printf 'FAIL: built kernel image packages are not signed and verified\n' >&2
    failures=$((failures + 1))
fi
if ! grep -Fq 'require_enrolled_mok' "${ROOT}/scripts/install-kernel.sh" ||
   ! grep -Fq 'sbverify --cert' "${ROOT}/scripts/install-kernel.sh"; then
    printf 'FAIL: kernel install does not verify every image against an enrolled certificate\n' >&2
    failures=$((failures + 1))
fi
if ! grep -Fq -- '-F sig_key' "${ROOT}/scripts/install-nvidia.sh" ||
   ! grep -Fq 'modprobe nvidia' "${ROOT}/scripts/install-nvidia.sh"; then
    printf 'FAIL: NVIDIA verification does not bind signatures to MOK and load the module\n' >&2
    failures=$((failures + 1))
fi

(( failures == 0 )) || exit 1
printf 'PASS: shell checks, help smoke tests, and Bugbot regressions\n'
