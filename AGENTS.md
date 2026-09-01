# AGENTS.md — guidance for AI agents working on xenOS

## Working model
- Kernel = hand-written C3 (`kernel/src/*.c3`), built with c3c. Userspace = cross-built
  static/shared musl, never hand-written.
- Houses: same perf budget, cooperative scheduling (`g_up[]`, `g_sock[]` global tables),
  fd-typed kernel, ext4 read-only, x86_64 syscall ABI.
- Every milestone is boot-verified (QEMU TCG) and committed. Do not claim completion
  without a real boot/output.

## Using agent-map (SOFT requirement)
When exploring, patching, or reasoning about the **C3 kernel codebase** (`kernel/`, `xk_*.c3`),
prefer the **agent-map tool** (`xenos` skill, repo `xenOS-AI/agent-map`) to get a precise
parsed-C3 symbol index and dependency graph (`c3c -P compile-only` → JSON) instead of
grep/searching by hand.

This is a **soft requirement**: use it when it clearly helps (kernel symbol/dependency
navigation, refactors, adding new `xk_*.c3` modules, tracing symbol interdependencies).
It is NOT mandatory for quick read-only greps, userspace cross-build work, or tiny
single-file patches — use judgment and don't let tooling overhead slow you down.

Useful agent-map use cases here:
- Mapping symbol/dependency interconnections in `xk_wl.c3`, `xk_linux.c3`, `xk_ext4.c3`.
- Verifying a function is referenced/defined before touching it.
- Adding a new kernel module or driver cleanly into the dependency graph.