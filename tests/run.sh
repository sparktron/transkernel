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

(( failures == 0 )) || exit 1
printf 'PASS: shell syntax, strict-mode policy, and help smoke tests\n'
