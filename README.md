# Jammy Modern HWE

This project keeps an Ubuntu 22.04 (Jammy) userspace while providing a separately
packaged Linux 7.0 kernel and controlled hardware-enablement updates. It does not
add repositories from another Ubuntu release and it never replaces or removes the
stock Ubuntu kernel.

The build is pinned to Linux **7.0.14**, the final 7.0.y release, with SHA-256
`de9999b784d2293f00d39c62d8f92a08ab8a54bc4e80ffd250a0c09cb07a0f98`.
Linux 7.0.y is no longer the current stable series; using this exact series is an
explicit project constraint, not a claim that it receives ongoing upstream fixes.

## Safety model

- Audit and validation are read-only by default and write reports only below
  `artifacts/`.
- Scripts that change the host require `--apply`; otherwise they print a plan.
- All mutating scripts require Jammy and reject globally configured non-Jammy
  Ubuntu archives.
- The running kernel is never removed. Kernel installation requires a stock
  Ubuntu kernel to remain installed.
- Firmware is installed as a versioned overlay package under
  `/lib/firmware/updates`, using an explicit file selection.
- Secure Boot installations fail closed unless the custom kernel image is already
  signed with a trusted key.

## Workflow

```bash
./scripts/audit-host.sh
./scripts/install-build-deps.sh              # plan
sudo ./scripts/install-build-deps.sh --apply
./scripts/build-kernel.sh
sudo ./scripts/install-kernel.sh --from build/packages --apply
sudo ./scripts/install-microcode.sh --apply
# Reboot, then record the loaded revision:
sudo ./scripts/install-microcode.sh verify --apply
sudo ./scripts/install-nvidia.sh --apply
./scripts/validate-system.sh
```

Do not run the install steps until the audit has identified the actual target
hardware. The machine on which this repository was created is not the requested
GU405/Panther Lake target; see `docs/current-host.md`.

Firmware is a separate, evidence-driven step:

```bash
./scripts/install-firmware.sh audit
./scripts/install-firmware.sh fetch
# Copy firmware/selection.example to a host-specific file and list exact blobs.
./scripts/install-firmware.sh build --selection firmware/selection.host
sudo ./scripts/install-firmware.sh install --package dist/jammy-modern-firmware_*.deb --apply
```

Read `docs/architecture.md`, `docs/compatibility.md`, and
`docs/secure-boot.md` before installation. Recovery procedures are in
`docs/rollback.md`; the acceptance matrix is `docs/test-matrix.tsv`.

## What the kernel build produces

Upstream `bindeb-pkg` produces versioned `linux-image` and `linux-headers` Debian
packages. Its `linux-image` package contains the matching modules rather than a
separate `linux-modules` package. This still provides clean dpkg ownership,
parallel installation, initramfs/GRUB integration, and DKMS headers without
pretending to be an Ubuntu archive kernel ABI package.

## Authoritative inputs

- Kernel source: <https://www.kernel.org/pub/linux/kernel/v7.x/>
- Kernel release verification: <https://www.kernel.org/signature.html>
- Upstream firmware: <https://gitlab.com/kernel-firmware/linux-firmware>
- Kernel module signing: <https://docs.kernel.org/admin-guide/module-signing.html>
