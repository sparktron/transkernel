#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

readonly MICROCODE_STATE_DIR="/var/lib/jammy-modern-hwe"
readonly MICROCODE_STATE_FILE="${MICROCODE_STATE_DIR}/microcode-install-state"

umask 077

action=install
apply=false
expected_revision=""
if [[ ${1:-} == verify ]]; then
    action=verify
    shift
fi
while (($#)); do
    case "$1" in
        --apply) apply=true; shift ;;
        --expected-revision)
            [[ $# -ge 2 ]] || die "--expected-revision needs a revision"
            expected_revision=$2
            shift 2
            ;;
        -h|--help)
            printf 'Usage: %s [--apply] | verify [--expected-revision REVISION] [--apply]\n' "$0"
            exit 0
            ;;
        *) die "usage: $0 [--apply] | verify [--expected-revision REVISION] [--apply]" ;;
    esac
done
[[ -z ${expected_revision} || ${action} == verify ]] ||
    die "--expected-revision is valid only with verify"
[[ -z ${expected_revision} || ${expected_revision} =~ ^0x[[:xdigit:]]+$ ]] ||
    die "--expected-revision must be a hexadecimal revision such as 0x123"

require_jammy
check_ubuntu_sources_are_jammy --
vendor="$(lscpu 2>/dev/null | awk -F: '/Vendor ID/{gsub(/[[:space:]]/, "", $2); print $2}')"
[[ ${vendor} == GenuineIntel ]] || die "Intel CPU required; found ${vendor:-unknown}"

boot_log="$(journalctl -k -b --no-pager 2>/dev/null | grep -i 'microcode.*revision' | tail -n1 || true)"
current_revision="$(awk -F: '/^microcode/{gsub(/[[:space:]]/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
candidate="$(apt-cache policy intel-microcode | awk '/Candidate:/{print $2}')"
[[ -n ${candidate} && ${candidate} != '(none)' ]] || die "no intel-microcode candidate in configured Jammy repositories"
installed="$(dpkg-query -W -f='${Version}' intel-microcode 2>/dev/null || true)"
log "boot-reported revision: ${boot_log:-not reported}"
log "current /proc/cpuinfo revision: ${current_revision:-not reported}"
log "installed package: ${installed:-none}; Jammy candidate: ${candidate}"

if [[ ${action} == verify ]]; then
    [[ -n ${installed} ]] || die "intel-microcode is not installed"
    [[ -n ${current_revision} ]] || die "the running kernel reports no microcode revision in /proc/cpuinfo"
    if [[ -n ${expected_revision} ]]; then
        [[ ${current_revision,,} == "${expected_revision,,}" ]] ||
            die "running microcode ${current_revision} does not match expected supported revision ${expected_revision}"
        verification="running revision matches explicit supported revision ${expected_revision}"
    else
        [[ -r ${MICROCODE_STATE_FILE} ]] ||
            die "no recorded pre-install state; supply --expected-revision with a supported revision"
        state_boot_id=""
        state_pre_revision=""
        state_package_after=""
        while IFS='=' read -r state_key state_value; do
            case "${state_key}" in
                boot_id) state_boot_id=${state_value} ;;
                pre_revision) state_pre_revision=${state_value} ;;
                package_after) state_package_after=${state_value} ;;
            esac
        done <"${MICROCODE_STATE_FILE}"
        [[ -n ${state_boot_id} && -n ${state_pre_revision} && -n ${state_package_after} ]] ||
            die "recorded microcode install state is incomplete"
        [[ -n ${boot_id} && ${boot_id} != "${state_boot_id}" ]] ||
            die "the host has not rebooted since the microcode package was installed"
        [[ ${state_pre_revision} != unknown && ${current_revision,,} != "${state_pre_revision,,}" ]] ||
            die "microcode revision did not change after reboot; supply a verified supported revision explicitly if no change is expected"
        [[ ${installed} == "${state_package_after}" ]] ||
            die "installed microcode package changed after the recorded installation"
        verification="revision changed from ${state_pre_revision} to ${current_revision} after reboot"
    fi
    log "verification succeeded: ${verification}"
    if confirm_apply "${apply}"; then
        require_root
        mkdir -p "${MICROCODE_STATE_DIR}"
        chmod 0700 "${MICROCODE_STATE_DIR}"
        printf '%s verified=%s package=%s boot_log=%q\n' "$(date -u +%FT%TZ)" \
            "${current_revision}" "${installed}" "${boot_log:-not-reported}" \
            >>"${MICROCODE_STATE_DIR}/microcode-history.log"
        chmod 0600 "${MICROCODE_STATE_DIR}/microcode-history.log"
    fi
    exit 0
fi

log "would install/upgrade intel-microcode and rebuild all initramfs images"
if confirm_apply "${apply}"; then
    require_root
    mkdir -p "${MICROCODE_STATE_DIR}"
    chmod 0700 "${MICROCODE_STATE_DIR}"
    apt-get install --no-install-recommends intel-microcode
    update-initramfs -u -k all
    installed_after="$(dpkg-query -W -f='${Version}' intel-microcode 2>/dev/null || true)"
    [[ -n ${installed_after} ]] || die "intel-microcode was not installed successfully"
    state_tmp="$(mktemp --tmpdir="${MICROCODE_STATE_DIR}" microcode-state.XXXXXX)"
    trap 'rm -f -- "${state_tmp}"' EXIT
    {
        printf 'installed_at=%s\n' "$(date -u +%FT%TZ)"
        printf 'boot_id=%s\n' "${boot_id:-unknown}"
        printf 'pre_revision=%s\n' "${current_revision:-unknown}"
        printf 'package_before=%s\n' "${installed:-none}"
        printf 'package_after=%s\n' "${installed_after}"
        printf 'candidate=%s\n' "${candidate}"
    } >"${state_tmp}"
    chmod 0600 "${state_tmp}"
    mv -- "${state_tmp}" "${MICROCODE_STATE_FILE}"
    trap - EXIT
    printf '%s before=%s package_before=%s package_after=%s boot_log=%q\n' \
        "$(date -u +%FT%TZ)" "${current_revision:-unknown}" "${installed:-none}" \
        "${installed_after}" "${boot_log:-not-reported}" \
        >>"${MICROCODE_STATE_DIR}/microcode-history.log"
    chmod 0600 "${MICROCODE_STATE_DIR}/microcode-history.log"
    log "reboot required; run verify afterward to require a recorded revision transition"
fi
