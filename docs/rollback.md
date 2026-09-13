# Rollback and recovery

## Before first custom boot

Confirm a stock `linux-image-*-generic` is installed, its initramfs exists, and its
GRUB Advanced Options entry boots. Keep a Jammy live USB. Record encryption and
root filesystem details from the audit bundle.

## Kernel does not boot, black screen, or Secure Boot rejection

1. In GRUB select **Advanced options for Ubuntu** and a stock Ubuntu kernel.
2. Once booted, run `./scripts/rollback.sh plan`.
3. Remove only the named custom kernel packages:
   `sudo ./scripts/rollback.sh kernel --release 7.0.14-jammy-modern --apply`.
4. Regenerate initramfs and GRUB; the script does this after package removal.

The rollback script refuses to remove the running kernel and refuses names without
the `-jammy-modern` suffix.

## NVIDIA DKMS failure or display failure

Boot the stock kernel, select a TTY if necessary, and inspect `dkms status`,
`journalctl -k -b`, and `/var/lib/dkms/nvidia/*/build/make.log`. Do not purge the
graphics stack. Reinstall the previously recorded Jammy NVIDIA metapackage/version
with apt, or select integrated graphics using the vendor-supported mechanism.
Keep the display manager stopped only for the duration required to repair packages.
The installer records the exact pre-change NVIDIA package set under
`/var/lib/jammy-modern-hwe/nvidia-packages-before-*.tsv`; use that list to install
the prior Jammy versions explicitly after reviewing apt's simulated transaction.

## Microcode rollback

Microcode package changes are recorded in
`/var/lib/jammy-modern-hwe/microcode-history.log`. Prefer installing a fixed Jammy
security update rather than downgrading. If a vendor-confirmed regression requires
a downgrade, use `apt-cache policy intel-microcode`, install the exact previously
recorded Jammy version, rebuild all initramfs images, power-cycle, and run
`install-microcode.sh verify --apply`. Do not remove early microcode from initramfs
without a vendor/security assessment.

## Firmware regression

Boot either kernel with working storage, then run:

```bash
sudo ./scripts/rollback.sh firmware --apply
sudo update-initramfs -u -k all
```

This removes only `jammy-modern-firmware`; Jammy's `linux-firmware` package remains
installed and becomes authoritative again.

## Broken Wi-Fi

Use Ethernet/USB Ethernet or cached packages, remove the overlay firmware package,
rebuild initramfs, and power-cycle (not only reboot) if the adapter retains state.
Capture the failed boot log first when possible.

## Suspend regression

Boot the stock kernel. Preserve the custom kernel for log comparison unless it
prevents safe operation. Collect the prior boot with
`journalctl -k -b -1 --no-pager` and record AC/battery, GPU state, and sleep mode.

## GRUB or unbootable root filesystem

From a Jammy live USB, unlock and mount the root filesystem plus separate `/boot`
and EFI partitions, bind-mount `/dev`, `/proc`, `/sys`, and `/run`, then chroot.
Reinstall the stock kernel metapackage, run `update-initramfs -c -k <stock-release>`,
and run `update-grub`. Do not delete custom files manually from `/boot` or
`/lib/modules`; let dpkg remove packages after the system boots.
