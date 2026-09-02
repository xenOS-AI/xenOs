# Contributing

## Change workflow

1. Read the relevant wiki page and module entry before editing.
2. Keep hand-written kernel C3 separate from cross-built userspace artifacts.
3. Update this wiki for changed architecture, contracts, build inputs, or
   operational steps; update source-level Doxygen comments for public symbols.
4. Run the focused check and a QEMU boot verification for kernel behavior.
5. Do not commit generated build output, tokens, or machine-local cross sysroots.

## Writing documentation

Use relative Markdown links and concise headings. Put stable design rationale
in `docs/`; place local, symbol-specific explanation beside the code using
Doxygen comments where supported. For a new kernel module, add one row to
`kernel-modules.md`, link it from the relevant architecture section, and add it
to the kernel compile list in `build.sh`.

## Doxygen policy

`Doxyfile` produces a searchable source reference from repository sources and
this wiki. It intentionally excludes generated binary-array C3 files because
they make the output noisy and have no hand-maintained API. Build the site with
`doxygen Doxyfile`; do not commit `build/docs/doxygen/`.
