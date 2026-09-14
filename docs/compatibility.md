# Compatibility evidence and risk register

Status values are `works`, `partial`, `fails`, and `not-tested`. Until an audit and
test run occurs on the target, all target-specific entries remain `not-tested`.

## Highest risks

- **Exact hardware identity:** the GU405-family marketing name is insufficient.
  Capture every PCI, USB, ACPI, DMI, and codec ID on the physical machine.
- **Kernel lifecycle:** 7.0.14 is the final 7.0.y point release, so continued
  security maintenance is an operational responsibility.
- **Intel graphics userspace:** a new Xe device may initialize in the kernel but
  still lack device IDs or features in Jammy Mesa, Vulkan, VA-API, or the display
  stack. Test each layer separately before considering a backport.
- **NVIDIA packaging:** package names and supported GPUs depend on the enabled
  Jammy NVIDIA archive at install time. The install script checks the apt candidate
  and refuses downgrades; it does not assert that 580 supports an unidentified GPU.
- **Secure Boot:** an upstream-built kernel is not Canonical-signed. The build and
  install scripts bind every EFI image to an explicitly enrolled certificate;
  NVIDIA DKMS modules must expose that certificate's subject key ID and load
  successfully on each target kernel.
- **Suspend/external display topology:** mux routing and USB-C/HDMI wiring are
  model-specific and cannot be inferred from GPU presence.
- **Camera/audio:** IPU and Sound Open Firmware often need exact firmware and
  userspace topology files in addition to kernel support.

## Unsupported-device record template

Copy this block once per failure:

```text
Hardware ID:
DMI/BIOS version:
Expected driver:
Driver currently bound:
Symptom:
Kernel log evidence:
Upstream commit/version adding support:
Required firmware filenames and source commit:
Userspace dependency/API evidence:
Smallest proposed change:
Result after change:
Rollback result:
```

## Graphics escalation gate

Do not change Mesa/libdrm when `dmesg` shows missing firmware or a failed kernel
probe. Consider a Jammy-compatible backport only after collecting `drm_info`,
`glxinfo -B`, `vulkaninfo --summary`, `vainfo`, compositor logs, package versions,
and a successful DRM driver bind. Any backport must be locally packaged or come
from a documented Jammy-targeted source, with an exact package manifest and apt
rollback command. Noble or later archives must never appear in apt sources.

## ASUS platform policy

Test upstream `asus-wmi`, `asus-nb-wmi`, `asus-armoury`, `platform_profile`, hwmon,
battery threshold, hotkey, fan, and mux interfaces first. Treat `asusctl` as an
optional userspace convenience. Out-of-tree patches require the ACPI/WMI GUID or
method, failing log, upstream status, and a documented reason 7.0.14 is inadequate.
