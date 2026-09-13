# Packaging notes

The kernel uses upstream `make bindeb-pkg` with a unique local version. Do not add
Ubuntu archive package names, ABI numbers, or Canonical signing claims to these
packages. Inspect with `dpkg-deb -I` and `dpkg-deb -c` before installation.

The firmware builder creates `jammy-modern-firmware`, an overlay depending on
Jammy's `linux-firmware`. It owns only selected paths under
`/lib/firmware/updates`, plus its source commit and checksums. It neither overwrites
nor diverts files owned by Ubuntu.

Release artifacts must include `.deb`, SHA256 manifests, source/config hashes,
compiler version, build log, and the audit/test artifact IDs used for approval.

