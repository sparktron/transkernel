# Current development-host observation

Read-only inspection on 2026-09-13 found:

- Ubuntu 22.04.5 (Jammy), kernel `6.8.0-138-generic`.
- Intel Core i9-10900K, 20 logical CPUs; this is not Panther Lake.
- NVIDIA RTX 3090 (`10de:2204`) using the Jammy
  `nvidia-driver-595-open`/595.91.07 DKMS module; this is not the target RTX 5070 Ti.
- Samsung NVMe (`144d:a80c`) using `nvme` and Realtek RTL8125 (`10ec:8125`) using
  `r8169`.
- Secure Boot disabled.
- Early microcode updated from `0xf0` to `0x100` during boot.
- `lsusb` and `fwupdmgr` were unavailable in the sandboxed session, so USB and
  LVFS inventory are unknown.

These facts only validate that the scripts can be developed on Jammy. They provide
no compatibility evidence for the GU405-class target. Run `audit-host.sh` on that
machine before selecting firmware or claiming support.
