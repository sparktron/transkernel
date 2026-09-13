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
if ! APT_SOURCES_ROOT="${apt_root}" check_ubuntu_sources_are_jammy; then
    printf 'FAIL: Jammy pocket was rejected\n' >&2
    failures=$((failures + 1))
fi
printf 'deb http://archive.ubuntu.com/ubuntu future main\n' >"${apt_root}/sources.list"
if (APT_SOURCES_ROOT="${apt_root}" check_ubuntu_sources_are_jammy >/dev/null 2>&1); then
    printf 'FAIL: unknown Ubuntu suite was accepted\n' >&2
    failures=$((failures + 1))
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

(( failures == 0 )) || exit 1
printf 'PASS: shell checks, help smoke tests, and Bugbot regressions\n'
