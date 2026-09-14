# Secure Boot

Full builds require `--signing-key` (PEM private key) and `--signing-cert` (PEM
X.509 certificate). The build post-processes
every generated `linux-image-*-jammy-modern` package with `sbsign`, verifies each
packaged image against the supplied certificate, regenerates package metadata,
and only then creates `SHA256SUMS`. `--prepare-only` does not require signing
material because it produces no installable packages.

`install-kernel.sh` detects Secure Boot and requires `--trusted-cert` in that
mode. It proves that certificate is enrolled with `mokutil --test-key`, verifies
every packaged image with `sbverify --cert`, installs only packages covered by
the trusted manifest digest, and verifies each installed image again. Passing a
bypass flag is intentionally unsupported.

A complete deployment requires two distinct signatures:

1. Sign each EFI-stub kernel image using `sbsign` with the PEM certificate and
   private key. Convert that same certificate to DER and enroll it with
   `mokutil --import`.
2. Configure `CONFIG_MODULE_SIG` and sign every external DKMS module, including
   NVIDIA, with a key trusted by that kernel. Ubuntu's DKMS/MOK integration may
   sign DKMS modules, but it must be verified for the custom kernel.

Recommended controlled procedure:

1. Generate the key offline or on an encrypted administrative system. Protect the
   private key; do not commit it or leave it in the kernel source tree.
2. Enroll only the public DER certificate with MOK and complete enrollment in the
   firmware UI on reboot.
3. Pass the key and PEM certificate to `build-kernel.sh`, retain the manifest
   digest printed by the build, and pass that digest plus the enrolled DER form
   of the same certificate to `install-kernel.sh`. The installer converts the
   DER certificate to a temporary PEM file for exact `sbverify` checks.
4. Pass the same enrolled DER certificate used by Ubuntu DKMS to
   `install-nvidia.sh --mok-cert`. The script compares the X.509 subject key ID
   to every core NVIDIA module's `sig_key` value.
5. Load verification can only be performed for the running kernel. For any other
   target the NVIDIA script exits unsuccessfully after signature validation;
   boot that target and rerun with `--kernel-release "$(uname -r)"`.
6. Confirm `mokutil --sb-state`, kernel lockdown state, `nvidia-smi`, PRIME,
   display operation, and suspend/resume behavior.

Never use a passwordless private key stored permanently in `/var/lib/dkms` merely
for convenience. If key custody and repeatable signed-package generation are not
available, use `--prepare-only`; do not produce or install kernel packages and do
not claim Secure Boot support.
