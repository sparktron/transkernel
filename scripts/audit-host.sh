#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

umask 077

usage() {
    cat <<'EOF'
Usage: audit-host.sh [--output DIR]

Collect a read-only, timestamped diagnostic bundle. Reports can contain serial
numbers, MAC addresses, filesystem UUIDs, and kernel command-line data; review
before sharing.
EOF
}

output_root="${PROJECT_ROOT}/artifacts/audit"
while (($#)); do
    case "$1" in
        --output) [[ $# -ge 2 ]] || die "--output needs a directory"; output_root=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
host="$(hostname 2>/dev/null || printf unknown-host)"
mkdir -p -- "${output_root}"
[[ -d ${output_root} && ! -L ${output_root} ]] ||
    die "audit output must be a real directory, not a symbolic link: ${output_root}"
bundle="$(mktemp -d -- "${output_root}/${host}-${timestamp}.XXXXXX")"
[[ -d ${bundle} && ! -L ${bundle} ]] || die "failed to create a safe audit directory"
chmod 0700 "${bundle}"

run() {
    local name=$1
    local status=0
    shift
    {
        printf 'command:'
        printf ' %q' "$@"
        printf '\n\n'
        if ! have "$1"; then
            printf 'NOT AVAILABLE: %s\n' "$1"
            status=127
        else
            "$@" || status=$?
        fi
    } >"${bundle}/${name}.txt" 2>&1
    if (( status != 0 )); then
        printf '%s\n' "exit-status: ${status}" >>"${bundle}/${name}.txt"
    fi
    return 0
}

run_shell() {
    local name=$1 command=$2
    {
        printf 'command: %s\n\n' "${command}"
        bash -o pipefail -c "${command}"
    } >"${bundle}/${name}.txt" 2>&1 || {
        local status=$?
        printf '%s\n' "exit-status: ${status}" >>"${bundle}/${name}.txt"
        return 0
    }
}

log "collecting read-only diagnostics in ${bundle}"
run os-release cat /etc/os-release
run lsb-release lsb_release -a
run uname uname -a
run cpu lscpu
# shellcheck disable=SC2016
run cpu-vulnerabilities sh -c 'for f in /sys/devices/system/cpu/vulnerabilities/*; do printf "%s: " "${f##*/}"; cat "$f"; done'
run pci lspci -nnk
run usb lsusb -tv
run modules lsmod
run block lsblk -e 7 -o NAME,KNAME,TYPE,SIZE,FSTYPE,FSVER,LABEL,UUID,PARTUUID,MOUNTPOINTS,MODEL,SERIAL,TRAN
run filesystems findmnt --all --real -o TARGET,SOURCE,FSTYPE,OPTIONS
run nvme-list nvme list
# shellcheck disable=SC2016
run_shell nvme-smart 'if command -v nvme >/dev/null 2>&1; then for d in /dev/nvme[0-9]; do [ -e "$d" ] || continue; printf "device: %s\n" "$d"; nvme smart-log "$d"; done; else printf "NOT AVAILABLE: nvme\n"; exit 127; fi'
run network ip -details link show
run rfkill rfkill list
run bluetooth bluetoothctl show
run audio-devices aplay -l
run audio-recording arecord -l
run firmware-devices fwupdmgr get-devices --show-all-devices
run firmware-updates fwupdmgr get-updates
run secure-boot mokutil --sb-state
run mok-list mokutil --list-enrolled
run dkms dkms status
run nvidia-smi nvidia-smi -q
run prime-select prime-select query
run grub-defaults cat /etc/default/grub
run grub-env grub-editenv list
run_shell grub-menu 'grep -E "^[[:space:]]*(submenu|menuentry) " /boot/grub/grub.cfg 2>/dev/null || true'
run kernel-cmdline cat /proc/cmdline
run dmi dmidecode
# shellcheck disable=SC2016
run dmi-sysfs sh -c 'for f in /sys/class/dmi/id/{bios_date,bios_version,board_name,board_vendor,product_name,product_version,sys_vendor}; do [ -r "$f" ] && printf "%s: %s\n" "${f##*/}" "$(cat "$f")"; done'
run sensors sensors
run powerprofiles powerprofilesctl list
run upower upower -d
run thunderbolt boltctl list
run usb4-domain-tree tree /sys/bus/thunderbolt/devices
run acpi-tree find /sys/bus/acpi/devices -maxdepth 2 -type f -print
run platform-profile sh -c 'find /sys/firmware/acpi /sys/class/platform-profile /sys/class/hwmon -maxdepth 3 -type f -readable -print 2>/dev/null'
run modinfo-asus-wmi modinfo asus_wmi
run modinfo-asus-armoury modinfo asus_armoury
run modinfo-xe modinfo xe
run modinfo-i915 modinfo i915
run modinfo-iwlwifi modinfo iwlwifi
run modinfo-nvidia modinfo nvidia
# shellcheck disable=SC2016
run_shell packages 'dpkg-query -W -f="${binary:Package}\t${Version}\t${db:Status-Abbrev}\n" | sort'
run_shell apt-sources 'find /etc/apt -maxdepth 3 -type f \( -name "*.list" -o -name "*.sources" \) -print -exec sed -n "1,240p" {} \;'
# shellcheck disable=SC2016
run_shell firmware-package 'dpkg-query -W -f="${Package}\t${Version}\n" linux-firmware intel-microcode 2>/dev/null || true'
run_shell microcode 'journalctl -k -b --no-pager | grep -i microcode || true'
run_shell boot-errors 'journalctl -k -b --no-pager -p warning..alert'
run_shell hardware-log 'journalctl -k -b --no-pager | grep -Eai "firmware|drm|xe|i915|nvidia|iwlwifi|bluetooth|sof|snd|thunderbolt|usb4|typec|nvme|asus|wmi|acpi|suspend|resume"'
run dmesg dmesg --ctime

{
    printf 'created_utc=%s\n' "${timestamp}"
    printf 'host=%s\n' "${host}"
    printf 'audit_script_sha256='
    sha256sum "$0" | awk '{print $1}'
    printf 'warning=review for serial numbers, MAC addresses, UUIDs, and other identifiers before sharing\n'
} >"${bundle}/MANIFEST"

archive="${bundle}.tar.gz"
tar -C "${output_root}" -czf "${archive}" "$(basename "${bundle}")"
sha256sum "${archive}" >"${archive}.sha256"
chmod 0600 "${archive}" "${archive}.sha256"
log "audit complete: ${archive}"
