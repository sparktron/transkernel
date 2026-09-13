#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC2034,SC2155
readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

log() {
    printf '[jammy-modern-hwe] %s\n' "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

require_root() {
    [[ ${EUID} -eq 0 ]] || die "this operation requires root"
}

require_jammy() {
    local codename=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        codename="${VERSION_CODENAME:-}"
    fi
    [[ ${codename} == jammy ]] || die "Ubuntu 22.04/Jammy is required (found '${codename:-unknown}')"
}

check_ubuntu_sources_are_jammy() {
    local file line suite ubuntu_deb822
    while IFS= read -r -d '' file; do
        ubuntu_deb822=false
        if [[ ${file} == *.sources ]] &&
           grep -Eqi '^URIs:.*(archive\.ubuntu\.com|security\.ubuntu\.com|ports\.ubuntu\.com|ppa\.launchpadcontent\.net)' "${file}"; then
            ubuntu_deb822=true
        fi
        while IFS= read -r line; do
            [[ ${line} =~ ^[[:space:]]*# ]] && continue
            if [[ ${line} =~ ^[[:space:]]*deb(-src)?[[:space:]] ]] &&
               [[ ${line} =~ (archive\.ubuntu\.com|security\.ubuntu\.com|ports\.ubuntu\.com|ppa\.launchpadcontent\.net) ]]; then
                for suite in focal noble oracular plucky questing resolute; do
                    [[ ${line} =~ (^|[[:space:]/])${suite}($|[-/[:space:]]) ]] &&
                        die "non-Jammy Ubuntu suite '${suite}' is active in ${file}"
                done
            elif [[ ${ubuntu_deb822} == true ]] &&
                 [[ ${line} =~ ^[[:space:]]*Suites:[[:space:]]*(.*)$ ]]; then
                for suite in ${BASH_REMATCH[1]}; do
                    [[ ${suite} == jammy || ${suite} == jammy-* ]] ||
                        die "non-Jammy deb822 suite '${suite}' is active in ${file}"
                done
            fi
        done <"${file}"
    done < <(find /etc/apt/sources.list /etc/apt/sources.list.d -maxdepth 1 -type f \
        \( -name '*.list' -o -name '*.sources' -o -name 'sources.list' \) -print0 2>/dev/null)
}

confirm_apply() {
    local apply=${1:-false}
    [[ ${apply} == true ]] || {
        log "plan only; rerun with --apply to make changes"
        return 1
    }
    return 0
}

secure_boot_enabled() {
    have mokutil && mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'
}

stock_kernel_packages() {
    dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' 'linux-image-*-generic' 2>/dev/null |
        awk '$2 == "installed" {print $1}' || true
}
