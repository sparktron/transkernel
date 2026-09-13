# Secure Boot

The default build is suitable for a first boot only with Secure Boot disabled.
`install-kernel.sh` detects Secure Boot and refuses to install an unsigned kernel.
Passing a bypass flag is intentionally unsupported.

A complete deployment requires two distinct signatures:

1. Sign the EFI-stub kernel image using `sbsign` and a private key whose certificate
   is enrolled with `mokutil --import` (or trusted directly by firmware/shim).
2. Configure `CONFIG_MODULE_SIG` and sign every external DKMS module, including
   NVIDIA, with a key trusted by that kernel. Ubuntu's DKMS/MOK integration may
   sign DKMS modules, but it must be verified for the custom kernel.

Recommended controlled procedure:

1. Generate the key offline or on an encrypted administrative system. Protect the
   private key; do not commit it or leave it in the kernel source tree.
2. Enroll only the public DER certificate with MOK and complete enrollment in the
   firmware UI on reboot.
3. Sign the kernel image as part of a reproducible package post-processing step,
   then verify the packaged `/boot/vmlinuz-*` with `sbverify --list`.
4. Build/install NVIDIA, verify `modinfo -F signer nvidia`, then enable Secure Boot.
5. Confirm `mokutil --sb-state`, `keyctl %:.platform`, kernel lockdown state, and
   successful loading of every required module.

Never use a passwordless private key stored permanently in `/var/lib/dkms` merely
for convenience. If key custody and repeatable signed-package generation are not
yet designed, leave Secure Boot disabled and document that risk rather than
claiming support.

