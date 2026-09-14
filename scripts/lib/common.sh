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
    [[ ${1:-} == -- ]] || die "internal error: APT source validation requires an explicit allowlist separator"
    shift
    have python3 || die "python3 is required for fail-closed APT source validation"
    python3 - "${apt_root}" "$@" <<'PY' || die "APT source validation failed"
import pathlib
import re
import sys
from urllib.parse import urlsplit

root = pathlib.Path(sys.argv[1])
extra_hosts = {host.lower() for host in sys.argv[2:]}
approved_hosts = {
    "archive.ubuntu.com",
    "security.ubuntu.com",
    "ports.ubuntu.com",
    "ppa.launchpadcontent.net",
} | extra_hosts
validated = 0


def fail(path, line, message):
    location = f"{path}:{line}" if line else str(path)
    print(f"{location}: {message}", file=sys.stderr)
    raise SystemExit(1)


def host_is_approved(host):
    return host in approved_hosts or host.endswith(".archive.ubuntu.com")


def validate_source(path, line, uri, suites):
    global validated
    parsed = urlsplit(uri)
    host = (parsed.hostname or "").lower()
    if parsed.scheme not in {"http", "https"} or not host or parsed.username or parsed.password:
        fail(path, line, f"unsupported binary repository URI {uri!r}")
    if not host_is_approved(host):
        fail(path, line, f"unapproved binary repository host {host!r}")
    for suite in suites:
        if re.fullmatch(r"jammy(?:-[A-Za-z0-9][A-Za-z0-9._-]*)?", suite):
            continue
        if host in extra_hosts and suite == "/":
            continue
        fail(path, line, f"non-Jammy suite {suite!r} is active")
    validated += 1


def enabled_value(path, line, value):
    normalized = value.strip().lower()
    if normalized in {"no", "false", "0"}:
        return False
    if normalized in {"yes", "true", "1"}:
        return True
    fail(path, line, f"invalid Enabled value {value!r}")


def parse_legacy(path):
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(
            r"(deb|deb-src)\s+(?:\[([^]]*)\]\s+)?(\S+)\s+(\S+)(?:\s+.*)?",
            line,
            flags=re.IGNORECASE,
        )
        if not match:
            fail(path, line_number, "malformed or unsupported one-line APT source")
        source_type, options, uri, suite = match.groups()
        if source_type.lower() != "deb":
            continue
        if options:
            enabled = re.search(r"(?:^|\s)enabled\s*=\s*([^\s]+)", options, re.IGNORECASE)
            if enabled and not enabled_value(path, line_number, enabled.group(1)):
                continue
        validate_source(path, line_number, uri, [suite])


def parse_deb822(path):
    fields = {}
    field_lines = {}
    current = None
    stanza_line = 0

    def finish_stanza():
        nonlocal fields, field_lines, current, stanza_line
        if not fields:
            return
        if "enabled" in fields and not enabled_value(path, field_lines["enabled"], fields["enabled"]):
            fields, field_lines, current, stanza_line = {}, {}, None, 0
            return
        types = fields.get("types", "").split()
        if "deb" not in types:
            fields, field_lines, current, stanza_line = {}, {}, None, 0
            return
        uris = fields.get("uris", "").split()
        suites = fields.get("suites", "").split()
        if not uris or not suites:
            fail(path, stanza_line, "enabled binary Deb822 stanza requires URIs and Suites")
        for uri in uris:
            validate_source(path, field_lines["uris"], uri, suites)
        fields, field_lines, current, stanza_line = {}, {}, None, 0

    lines = path.read_text(encoding="utf-8").splitlines()
    for line_number, raw in enumerate(lines, 1):
        if not raw.strip():
            finish_stanza()
            continue
        if raw.lstrip().startswith("#"):
            continue
        if raw[0].isspace():
            if current is None:
                fail(path, line_number, "Deb822 continuation has no field")
            fields[current] += " " + raw.strip()
            continue
        if ":" not in raw:
            fail(path, line_number, "malformed Deb822 field")
        name, value = raw.split(":", 1)
        name = name.strip().lower()
        if not re.fullmatch(r"[a-z0-9-]+", name) or name in fields:
            fail(path, line_number, f"invalid or duplicate Deb822 field {name!r}")
        if not fields:
            stanza_line = line_number
        fields[name] = value.strip()
        field_lines[name] = line_number
        current = name
    finish_stanza()


source_files = []
main_list = root / "sources.list"
if main_list.is_file():
    source_files.append(main_list)
source_dir = root / "sources.list.d"
if source_dir.is_dir():
    source_files.extend(sorted(source_dir.glob("*.list")))
    source_files.extend(sorted(source_dir.glob("*.sources")))

for source_file in source_files:
    try:
        if source_file.suffix == ".sources":
            parse_deb822(source_file)
        else:
            parse_legacy(source_file)
    except (OSError, UnicodeError) as error:
        fail(source_file, 0, f"cannot read APT source: {error}")

if validated == 0:
    fail(root, 0, "no enabled binary APT sources were found")
PY
}

x509_subject_key_id() {
    local certificate=$1 details key_id
    have openssl || die "openssl is required to inspect X.509 certificates"
    [[ -r ${certificate} ]] || die "certificate is not readable: ${certificate}"
    if ! details="$(openssl x509 -in "${certificate}" -noout -ext subjectKeyIdentifier 2>/dev/null)"; then
        details="$(openssl x509 -inform DER -in "${certificate}" -noout -ext subjectKeyIdentifier 2>/dev/null)" ||
            die "certificate is not a readable PEM or DER X.509 certificate: ${certificate}"
    fi
    key_id="$(printf '%s\n' "${details}" | awk 'NR > 1 {gsub(/[^[:xdigit:]]/, ""); if (length) {print toupper($0); exit}}')"
    [[ ${key_id} =~ ^[[:xdigit:]]{40}$ ]] || die "certificate has no usable SHA-1 subject key identifier: ${certificate}"
    printf '%s\n' "${key_id}"
}

require_enrolled_mok() {
    local certificate=$1
    have mokutil || die "mokutil is required to prove certificate enrollment"
    have openssl || die "openssl is required to validate the MOK certificate"
    [[ -r ${certificate} ]] || die "MOK certificate is not readable: ${certificate}"
    openssl x509 -inform DER -in "${certificate}" -noout >/dev/null 2>&1 ||
        die "MOK certificate must be DER-encoded: ${certificate}"
    mokutil --test-key "${certificate}" >/dev/null 2>&1 ||
        die "certificate is not enrolled in the Machine Owner Key database: ${certificate}"
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
