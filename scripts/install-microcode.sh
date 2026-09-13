#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

action=install
apply=false
if [[ ${1:-} == verify ]]; then
    action=verify
    shift
elif [[ ${1:-} == -h || ${1:-} == --help ]]; then
    printf 'Usage: %s [--apply] | verify [--apply]\n' "$0"
    exit 0
fi
[[ ${1:-} == --apply ]] && { apply=true; shift; }
[[ $# -eq 0 ]] || die "usage: $0 [--apply] | verify [--apply]"

require_jammy
check_ubuntu_sources_are_jammy
vendor="$(lscpu 2>/dev/null | awk -F: '/Vendor ID/{gsub(/[[:space:]]/, "", $2); print $2}')"
[[ ${vendor} == GenuineIntel ]] || die "Intel CPU required; found ${vendor:-unknown}"

before="$(journalctl -k -b --no-pager 2>/dev/null | grep -i 'microcode.*revision' | tail -n1 || true)"
cpuinfo_revision="$(awk -F: '/^microcode/{gsub(/[[:space:]]/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
candidate="$(apt-cache policy intel-microcode | awk '/Candidate:/{print $2}')"
[[ -n ${candidate} && ${candidate} != '(none)' ]] || die "no intel-microcode candidate in configured Jammy repositories"
installed="$(dpkg-query -W -f='${Version}' intel-microcode 2>/dev/null || true)"
log "boot-reported revision: ${before:-not reported}"
log "current /proc/cpuinfo revision: ${cpuinfo_revision:-not reported}"
log "installed package: ${installed:-none}; Jammy candidate: ${candidate}"

if [[ ${action} == verify ]]; then
    [[ -n ${installed} ]] || die "intel-microcode is not installed"
    [[ -n ${cpuinfo_revision} || -n ${before} ]] || die "the running kernel reports no microcode revision"
    log "verification succeeded; compare this revision to the recorded pre-install value"
    if confirm_apply "${apply}"; then
        require_root
        mkdir -p /var/lib/jammy-modern-hwe
        printf '%s after=%s package=%s boot_log=%q\n' "$(date -u +%FT%TZ)" \
            "${cpuinfo_revision:-unknown}" "${installed}" "${before:-not-reported}" \
            >>/var/lib/jammy-modern-hwe/microcode-history.log
    fi
    exit 0
fi

log "would install/upgrade intel-microcode and rebuild all initramfs images"
if confirm_apply "${apply}"; then
    require_root
    mkdir -p /var/lib/jammy-modern-hwe
    {
        date -u +%FT%TZ
        printf 'before=%s\ninstalled=%s\ncandidate=%s\n' "${before}" "${installed:-none}" "${candidate}"
    } >>/var/lib/jammy-modern-hwe/microcode-history.log
    apt-get install --no-install-recommends intel-microcode
    update-initramfs -u -k all
    log "reboot required; compare journalctl microcode revision and append it to the history log"
fi
