# Validation plan

Run `validate-system.sh` once under the stock kernel and once under the custom
kernel. Give each report directory a descriptive label and update
`test-matrix.tsv`. Automatic checks are observational; physical I/O, suspend,
battery, and display routing require an operator.

## Required test sequence

1. Baseline: audit, quick validation, 30-minute CPU load, graphics API checks,
   NVMe SMART, networking, audio/video capture, ports, and five suspend cycles.
2. Kernel-only: repeat using 7.0.14 with stock firmware/userspace.
3. Firmware overlay, only if justified: repeat probe, graphics, Wi-Fi, Bluetooth,
   audio, camera, cold boot, and suspend.
4. NVIDIA open driver: test `nvidia-smi`, DKMS, OpenGL/Vulkan/CUDA, PRIME offload,
   dGPU idle power, external outputs, Wayland and X11 where both are required.
5. Power matrix: five cycles each on AC and battery, NVIDIA idle and active, lid
   close/open, and AC attach/remove. Capture the previous boot after every failure.
6. Storage: SMART plus a large sequential test only on designated scratch space;
   never benchmark the root filesystem without explicit capacity/wear approval.

`validate-system.sh --active --scratch-dir PATH` enables bounded stress-ng and fio
tests. It never initiates suspend, changes a platform profile, or writes outside
the selected scratch directory.

## Pass criteria

A subsystem is `works` only when its functional test passes and logs contain no
new driver errors compared with the stock baseline. `partial` means a documented
feature is absent or unreliable. Untested physical paths remain `not-tested`.

