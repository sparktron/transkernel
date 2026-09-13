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

git_worktree_is_clean() {
    local status
    status="$(git -C "$1" status --porcelain --untracked-files=all --ignore-submodules=none)" || return 1
    [[ -z ${status} ]]
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
    local apt_root=${APT_SOURCES_ROOT:-/etc/apt}
    local file line suite ubuntu_deb822 legacy source_uri
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
                legacy="${line#"${line%%[![:space:]]*}"}"
                legacy="${legacy#deb-src}"
                legacy="${legacy#deb}"
                legacy="${legacy#"${legacy%%[![:space:]]*}"}"
                if [[ ${legacy} == \[* ]]; then
                    [[ ${legacy} =~ ^\[[^]]*\][[:space:]]+(.*)$ ]] ||
                        die "malformed Ubuntu source in ${file}"
                    legacy=${BASH_REMATCH[1]}
                fi
                read -r source_uri suite _ <<<"${legacy}"
                [[ ${source_uri} =~ (archive\.ubuntu\.com|security\.ubuntu\.com|ports\.ubuntu\.com|ppa\.launchpadcontent\.net) ]] ||
                    continue
                [[ -n ${suite} ]] ||
                    die "malformed Ubuntu source in ${file}"
                [[ ${suite} == jammy || ${suite} == jammy-* ]] ||
                    die "non-Jammy Ubuntu suite '${suite:-unknown}' is active in ${file}"
            elif [[ ${ubuntu_deb822} == true ]] &&
                 [[ ${line} =~ ^[[:space:]]*Suites:[[:space:]]*(.*)$ ]]; then
                for suite in ${BASH_REMATCH[1]}; do
                    [[ ${suite} == jammy || ${suite} == jammy-* ]] ||
                        die "non-Jammy deb822 suite '${suite}' is active in ${file}"
                done
            fi
        done <"${file}"
    done < <(find "${apt_root}/sources.list" "${apt_root}/sources.list.d" -maxdepth 1 -type f \
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
    local state
    if ! have mokutil; then
        log "WARNING: mokutil is unavailable; treating Secure Boot state as enabled"
        return 0
    fi
    if ! state="$(mokutil --sb-state 2>/dev/null)"; then
        log "WARNING: Secure Boot state could not be read; treating it as enabled"
        return 0
    fi
    case ${state,,} in
        *'secureboot enabled'*) return 0 ;;
        *'secureboot disabled'*) return 1 ;;
        *)
            log "WARNING: Secure Boot state was not recognized; treating it as enabled"
            return 0
            ;;
    esac
}

stock_kernel_packages() {
    dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' 'linux-image-*-generic' 2>/dev/null |
        awk '$2 == "installed" {print $1}' || true
}
