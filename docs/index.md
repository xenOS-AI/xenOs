# xenOS wiki {#mainpage}

xenOS is a from-scratch x86_64 hobby operating system. Its boot path,
freestanding C3 kernel, drivers, graphical environment, and host build tools
are all maintained in this repository.

## Read in this order

1. [Architecture](architecture.md) — components, boundaries, and invariants.
2. [Build and run](build-and-run.md) — prerequisites, artifacts, and QEMU use.
3. [Boot and memory map](boot.md) — execution path from firmware to kernel.
4. [Kernel guide](kernel.md) — subsystem contracts and C3 conventions.
5. [Kernel module reference](kernel-modules.md) — ownership map for every
   hand-written kernel module.
6. [Userspace and host tools](userspace-and-tools.md) — generated blobs,
   cross-built programs, and repository tooling.
7. [Verification](verification.md) — checks, expected evidence, and limits.
8. [Contributing](contributing.md) — documentation and change workflow.

## Documentation conventions

* This wiki explains *why*, public contracts, data ownership, and how to run
  the project. Keep it updated with behavior changes.
* Source comments explain local implementation details. Use Doxygen-style
  `///` or `/** ... */` comments for new externally useful symbols when the C3
  syntax permits it.
* Generated C3 blobs (`xk_uprog.c3`, `xk_ublob.c3`, and `xk_dynblob.c3`) are
  deliberately excluded from Doxygen. Document their generators instead.
