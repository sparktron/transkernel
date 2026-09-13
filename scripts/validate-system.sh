#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: validate-system.sh [--output DIR] [--active --scratch-dir DIR]

Default checks are read-only. --active adds a 60-second stress-ng CPU run and a
bounded 1 GiB fio test in an explicitly supplied scratch directory. This script
never suspends the host or changes power/GPU/platform settings.
EOF
}

output_root="${PROJECT_ROOT}/artifacts/validation"
active=false
scratch=""
while (($#)); do
    case "$1" in
        --output) [[ $# -ge 2 ]] || die "--output needs a path"; output_root=$2; shift 2 ;;
        --active) active=true; shift ;;
        --scratch-dir) [[ $# -ge 2 ]] || die "--scratch-dir needs a path"; scratch=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
if ${active}; then
    [[ -n ${scratch} && -d ${scratch} && -w ${scratch} ]] ||
        die "--active requires a writable existing --scratch-dir"
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
release="$(uname -r)"
report="${output_root}/${release}-${timestamp}"
mkdir -p "${report}"
summary="${report}/SUMMARY.tsv"
printf 'check\tstatus\tnote\n' >"${summary}"

capture() {
    local name=$1
    shift
    local status
    {
        printf 'command:'
        printf ' %q' "$@"
        printf '\n\n'
        "$@"
    } >"${report}/${name}.txt" 2>&1 && status=0 || status=$?
    if (( status == 0 )); then
        printf '%s\tworks\texit 0\n' "${name}" >>"${summary}"
    elif (( status == 127 )); then
        printf '%s\tnot-tested\tcommand unavailable\n' "${name}" >>"${summary}"
    else
        printf '%s\tfails\texit %s; inspect %s.txt\n' "${name}" "${status}" "${name}" >>"${summary}"
    fi
    return 0
}

capture_if_available() {
    local name=$1 command=$2
    shift 2
    if have "${command}"; then
        capture "${name}" "${command}" "$@"
    else
        printf '%s\tnot-tested\t%s unavailable\n' "${name}" "${command}" >>"${summary}"
    fi
}

capture uname uname -a
capture os-release cat /etc/os-release
capture cpu-online sh -c 'printf "configured="; nproc --all; printf "online="; nproc; cat /sys/devices/system/cpu/online'
capture cpufreq sh -c 'grep -H . /sys/devices/system/cpu/cpufreq/policy*/{scaling_driver,scaling_governor,scaling_cur_freq,cpuinfo_max_freq} 2>/dev/null'
capture cpuidle sh -c 'grep -H . /sys/devices/system/cpu/cpu0/cpuidle/state*/{name,usage,time} 2>/dev/null'
capture thermal sh -c 'grep -H . /sys/class/thermal/thermal_zone*/{type,temp} 2>/dev/null'
capture drm-kernel sh -c 'lspci -nnk | grep -A4 -Ei "VGA|3D|Display"; journalctl -k -b --no-pager | grep -Eai "drm|xe|i915|nvidia"'
capture_if_available drm-info drm_info
capture_if_available opengl glxinfo -B
capture_if_available vulkan vulkaninfo --summary
capture_if_available vaapi vainfo
capture_if_available nvidia-smi nvidia-smi
capture_if_available nvidia-module modinfo nvidia
capture_if_available dkms dkms status
capture storage lsblk -e 7 -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL,TRAN
capture_if_available nvme-list nvme list
capture nvme-errors bash -o pipefail -c \
    '! journalctl -k -b --no-pager | grep -Eai "nvme.*(I/O.*error|failed|timeout[, :].*(expired|abort|reset)|resetting|abort)"'
capture network ip -details address show
capture_if_available wifi iw dev
capture_if_available rfkill rfkill list
capture_if_available bluetooth bluetoothctl show
capture_if_available thunderbolt boltctl list
capture usb sh -c 'lsusb -tv; find /sys/class/typec /sys/bus/thunderbolt/devices -maxdepth 3 -type f -readable -print 2>/dev/null'
capture audio sh -c 'aplay -l; arecord -l'
capture platform sh -c 'find /sys/class/power_supply /sys/class/hwmon /sys/firmware/acpi -maxdepth 3 -type f -readable -print 2>/dev/null'
capture sleep-config sh -c 'cat /sys/power/mem_sleep /sys/power/state; systemctl status systemd-suspend.service --no-pager || true'
capture warnings journalctl -k -b --no-pager -p warning..alert

if ${active}; then
    if have stress-ng; then
        capture cpu-stress stress-ng --cpu 0 --timeout 60s --metrics-brief --verify
    else
        printf 'cpu-stress\tnot-tested\tstress-ng unavailable\n' >>"${summary}"
    fi
    if have fio; then
        free_kib="$(df --output=avail -k "${scratch}" | tail -n1 | tr -d ' ')"
        (( free_kib >= 3145728 )) || die "scratch directory needs at least 3 GiB free"
        capture storage-active fio --name=jammy-modern-validation \
            --filename="${scratch%/}/jammy-modern-fio.test" --size=1G --rw=readwrite \
            --bs=1M --direct=1 --iodepth=4 --fsync_on_close=1 --unlink=1
    else
        printf 'storage-active\tnot-tested\tfio unavailable\n' >>"${summary}"
    fi
fi

cat >>"${summary}" <<'EOF'
internal-display	not-tested	manual: OLED modes, brightness, blank/unblank
external-displays	not-tested	manual: HDMI, USB-C DP, dock, hotplug
input-camera-audio	not-tested	manual functional tests required
asus-platform	not-tested	manual: profiles, fans, charge threshold, hotkeys, mux
suspend-resume	not-tested	manual: five cycles per state from docs/test-plan.md
EOF
log "validation report: ${report}"
