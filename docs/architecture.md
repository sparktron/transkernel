# Architecture and implementation plan

## Boundary

The stable boundary is the Jammy userspace ABI. Kernel, firmware, CPU microcode,
and the NVIDIA kernel/userspace driver are replaceable HWE components, each with
an independent package boundary and rollback. Mesa, libdrm, systemd, glibc, and
the base apt sources stay on Jammy unless a measured failure justifies a narrowly
scoped backport.

```text
Jammy applications and robotics workloads
                |
Jammy glibc, systemd, Mesa/libdrm (initially unchanged)
                |
versioned NVIDIA open driver + selected firmware + intel-microcode
                |
linux-image/headers 7.0.14-jammy-modern (stock Ubuntu kernel retained)
                |
UEFI/ACPI hardware
```

## Phases and gates

1. Run `audit-host.sh` on the actual target and save the bundle outside the git
   repository if it contains serial numbers or MAC addresses.
2. Resolve every unknown PCI/USB/ACPI ID to an upstream driver and firmware name.
   Record evidence in `compatibility.md`. Do not patch based only on a marketing
   platform name.
3. Build the pinned kernel from the running Ubuntu config plus the small reviewed
   fragment in `kernel/config/modern-hwe.config`.
4. Inspect the config delta and Debian package contents. Boot with Secure Boot
   disabled first, while retaining a stock kernel GRUB entry.
5. Validate kernel-only behavior with stock Jammy firmware and graphics userspace.
6. Add only the firmware blobs shown missing or too old by kernel logs, packaging
   them as a versioned overlay.
7. Update microcode through Jammy's `intel-microcode` package and reboot.
8. Install a supported open NVIDIA package from configured Jammy repositories.
9. Run the full matrix against both kernels. Mesa/libdrm changes are a separate
   project only if render-node, API-version, or compositor evidence requires them.

Each gate requires an audit/validation artifact and a tested rollback. No script
commits, reboots, or changes firmware setup variables automatically.

## Package ownership

- Kernel: upstream `bindeb-pkg`; release suffix `-jammy-modern`; `/boot` and
  `/lib/modules/<release>` are versioned.
- Firmware: `jammy-modern-firmware`; exact selected files beneath
  `/lib/firmware/updates`; package includes source commit and file hashes.
- Microcode: Ubuntu `intel-microcode`; never bundled with the kernel package.
- NVIDIA: Ubuntu repository package selected by apt; never NVIDIA's `.run` file.

## Known design limitation

Linux 7.0.14 is the terminal 7.0.y point release and is not an LTS line. A
production system needs an explicit security-maintenance decision: rebuild with
backported fixes, or obtain approval to move to a maintained upstream series while
preserving this architecture. The scripts deliberately do not silently change the
requested kernel major/minor.

