# Verification

Every functional kernel milestone needs a real QEMU boot/output, not only a
successful compilation. The baseline sequence is:

```sh
./build.sh
./scripts/boot_verify.sh
```

Use `./run.sh serial` while investigating serial output, and use `./run.sh` for
the graphical desktop. The test scripts in `scripts/` are focused checks for
AI connectivity, mouse activity, and related host/guest interactions. Run the
smallest relevant self-test after a localized change, then perform the boot
verification before declaring a kernel change complete.

## Evidence to capture

* Exact command and exit status.
* Serial log or QEMU output showing the changed path executed.
* For graphical/input work, a screenshot or observed interaction as appropriate.
* Any unavailable dependency (for example a missing cross sysroot) and which
  validation it prevented.

## Known boundaries

The scheduler/context-switch design has explicit limitations around arbitrary
kernel preemption and long-lived stack locals. Ext4 is read-only. AHCI command
and link setup is implemented, but its QEMU data-DMA return path is a known
limitation. Retain these caveats in documentation and tests when touching the
affected subsystems.
