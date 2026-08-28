# xenOS "AI-First" Architecture — Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Redesign xenOS so an on-system AI/agent runtime is a *first-class citizen* of the
kernel, not an app bolted on at the end — a from-scratch tensor + tiny-LLM runtime, an
"agent ABI" syscall surface, an agent scheduler, and a display system the model can read
and act on, all running on the existing C3 kernel booting in QEMU.

**Architecture:** The agent is a ring-3 supervisor process (`agentd`) on a dedicated,
preemptible model-runner thread. The kernel exposes a small, declarative "agent ABI"
syscall set (`prompt`, `infer`, `act`, `announce`, `snapshot`) plus in-kernel primitives
(eigen allocator, KV-cache allocator, event-stream input, an inference quantum in the
scheduler). The framebuffer/window system becomes an *agent-readable scene graph* so the
model perceives the desktop as structured tokens, not pixels it must OCR. Everything
stays hand-written C3/asm; nothing external is downloaded.

**Tech Stack:** C3 (freestanding, `--x86cpu=baseline --x86vec=none`), NASM, GNU ld, QEMU
(qemu64, TCG, ~256 MB). No libc in-kernel. Model = a tiny hand-peeled quantized GPT
(i8 block / 2-bit-ish), integer matmul only (no SSE/AVX). Host `tools/` are freestanding
C3 (no libc) as today.

---

## Design Principles ("AI-first" means)

1. **The model is in-kernel data, not an app.** Tensors, KV cache, quantized weights and
   the sampler live in kernel/heap memory owned by a dedicated runtime — the scheduler
   treats generation like any other task (preemptible, quantum-limited).
2. **The syscall ABi is agent-shaped.** Rather than only low-level primitives, we add a
   small set of *intent-level* syscalls so an agent can say what it wants and the kernel/
   `agentd` does the bookkeeping. Every agent action is journaled (audit/trace by design).
3. **The display server is agent-readable.** The WM keeps a *declarative scene graph*
   (windows, title, text, buttons, pointer) that serializes to tokens an LLM consumes
   directly — so the OS is "legible" to itself, and the agent turns a natural-language
   request into a structured windowing action.
4. **Perception and action share one language.** Input (keyboard/mouse) is normalized into
   typed event *streams*; output (windows/text) is described by the scene graph. The model
   sees typed tokens both ways — symmetric, verifiable interaction.
5. **Self-snapshot / continuity.** The OS can serialize a bounded snapshot (processes, VFS
   catalog, scene graph, recent event stream) into a context window, giving the agent
   continuity across preemption and letting it "know" system state.

---

## Phase 0 — Foundational primitives (no NN yet)

Goal: land the allocators, event streams, and scene-graph refactor on which everything
else sits. All still TCG-friendly and passing `scripts/boot_verify.sh`.

### Task 0.1: "eigen"/tensor allocator in kernel heap
**Objective:** A slab allocator for fixed-size hidden/KV tensors in the kernel heap
(extend `xk_alloc.c3`).
**Files:** Modify `kernel/src/xk_alloc.c3`, `kernel/src/xk_mem.c3`.
**Verification:** A kernel self-test (boot → `about` or a `memtest` shell builtin) prints
alloc/free counts and reports no leaks over a loop.

### Task 0.2: typed event streams for input
**Objective:** Refactor PS/2 keyboard/mouse IRQ handling (`xk_kbd.c3`, `xk_mouse.c3`) so
it enqueues typed events (`key_down/up, scancode, char`, `rel/abs, x, y, buttons`,
`focus_changed`) into bounded ring buffers instead of writing directly to the WM.
**Files:** Modify `kernel/src/xk_kbd.c3`, `kernel/src/xk_mouse.c3`, `kernel/src/xk_wm.c3`.
**Verification:** Existing WM behavior is unchanged (drag/focus/click still work under
`boot_verify.sh`); `ps`/a debug command prints the head of each stream.

### Task 0.3: declarative scene graph in the WM
**Objective:** Refactor `xk_wm.c3` so windows are described as a small serializable
struct array (id, title, rect, z, focused, children/buttons list) and there is a
`snapshot_scene()` that renders that state to a token string.
**Files:** Modify `kernel/src/xk_wm.c3`, `kernel/src/xk_apps.c3`.
**Verification:** `snapshot_scene()` output is printed to the serial console; WM rendering
unchanged.

### Task 0.4: commit
**Verification:** `./build.sh` + `scripts/boot_verify.sh` pass; commit `feat(ai): event
streams + scene graph + tensor slab`.

---

## Phase 1 — On-board model runtime (tiny integer GPT)

Goal: a real but tiny generative model runs entirely in-kernel on the 256 MB / TCG target.
This is the hardest and most derisk-critical phase; keep the model deliberately small
(e.g. ~a few-MB parameter char-level GPT) so it fits and runs under TCG.

### Task 1.1: integer tensor ops (no SSE/AVX)
**Objective:** From-scratch `matmul`, `embed`, `rmsnorm/softmax`, `gelu-approx` in pure
C3 integer math. All reads go through raw pointer arithmetic (`(T*)ulong`), never
`any`/mixed-width — see golden rules.
**Files:** Create `kernel/src/xk_tensor.c3`.
**Verification:** A host-side test harness (`tools/tensor_test.c3`, freestanding C3) runs
a known small matmul and asserts numeric equality; kernel builds with
`--x86cpu=baseline --x86vec=none` (no `#UD`).

### Task 1.2: i8 block-quantized weight store
**Objective:** Container + loader for quantized weights (scale + i8 integer block, block
size 32/64). Weights generated at build time on the host by a new C3 tool.
**Files:** Create `kernel/src/xk_model.c3`, `tools/mkweights.c3`.
**Verification:** `mkweights` loads a trivial 2-layer model into `build/model.img`; kernel
loads it and the decode round-trips exactly (checksum printed).

### Task 1.3: KV cache + sampler + greedy decode
**Objective:** KV-cache allocator (in the tensor slab), an integer softmax/argmax sampler,
and a single-step `forward(token) -> logits` path so the model can *incrementally*
generate.
**Files:** Create `kernel/src/xk_llm.c3`.
**Verification:** A `model` shell builtin reads a prompt from the console, generates
N tokens, prints them, and stays responsive (proves the runtime yields to the scheduler).

### Task 1.4: inference quantum in the scheduler
**Objective:** Long generation is preemptible: forward steps are chunked so `xk_sched.c3`
can preempt between tokens (matching the existing PIT 100 Hz slice design).
**Files:** Modify `kernel/src/xk_sched.c3`, `kernel/src/xk_llm.c3`.
**Verification:** A busy char-GPT generation interleaves with the A/B/C demo tasks at 1 Hz
(extend the existing preemption demo); no `iretq` of crafted frames (existing rule).

### Task 1.5: commit
**Verification:** `./build.sh` + `boot_verify.sh` pass; `model` builtin generates text.
Commit `feat(ai): in-kernel integer char-GPT + preemptible KV sampling`.

---

## Phase 2 — Agent ABI (syscalls) + `agentd` supervisor

Goal: expose the runtime to ring-3 processes through an "AI-first" syscall set and host a
supervisor agent program that owns sessions, the tool registry, and the action journal.

### Task 2.1: extend the syscall gate (ABI additions)
**Objective:** Add to the existing `int 0x80` gate (`xk_sys.c3`, DPL-3) these
intent-level calls: `SYS_AGENT_POLICY` (register an agent/priority), `SYS_AGENT_ACT`
(run a named action through the tool registry), `SYS_AGENT_ANNOUNCE` (append to the
machine-readable action journal), `SYS_AGENT_SNAPSHOT` (serialize scene + VFS catalog +
recent events into a context buffer).
**Files:** Modify `kernel/src/xk_sys.c3`, and the asm stub or dispatch table.
**Verification:** `sysc`-style test from ring-3 (extend `user/sys_prog.asm`) issues each
new call and the kernel returns a deterministic result code; unknown calls still rejected.

### Task 2.2: `agentd` ring-3 supervisor
**Objective:** A new ring-3 program (following the distinct-CR3 pattern of
`user/sys_prog.asm`) that owns one model session, exposes a prompt loop, and dispatches
named actions from `SYS_AGENT_*` — the "agent OS" personality.
**Files:** Create `user/agentd.asm` (or C3 host-linked), modify `kernel/src/xk_uprog.c3`
embedding, `xk_umode.c3` launch.
**Verification:** `ps` shows `agentd`; it round-trips a prompt through `SYS_AGENT_*` and
prints the journal entry.

### Task 2.3: action journal (audit by design)
**Objective:** A bounded, append-only, token-serializable journal of every agent action
(actor, timestamp/ticks, action, args, result). Greppable via the shell.
**Files:** Create `kernel/src/xk_agent.c3`; wire into `SYS_AGENT_ANNOUNCE` and `xk_shell.c3`.
**Verification:** `journal` shell builtin lists recent entries; buffer never overruns.

### Task 2.4: sample agent — natural-language windowing
**Objective:** Wire scene-snapshot tokens + a keyword/pattern model so a typed
natural-language command (e.g. "open a clock window titled World Clock") becomes a
structured `SYS_AGENT_ACT` windowing action. Harder LLM reasoning is Phase 3.
**Files:** Modify `kernel/src/xk_apps.c3`, `kernel/src/xk_agent.c3`.
**Verification:** The prompt in a terminal yields the window; journal records the action.

### Task 2.5: commit
**Verification:** `boot_verify.sh` passes; `ps`, `journal`, and the NL-windowing demo work.
Commit `feat(ai): agent ABI syscalls + agentd supervisor + action journal`.

---

## Phase 3 — Self-aware display: model reads and drives the desktop

Goal: close the perception/action loop so the model governs the GUI through the scene
graph, not by guessing pixels.

### Task 3.1: scene-graph → context encoding
**Objective:** Render `snapshot_scene()` + recent event stream + `journal` head into a
bounded *context pack* the char-GPT consumes; keep it under the context window budget.
**Files:** Modify `kernel/src/xk_wm.c3`, `kernel/src/xk_llm.c3`, `kernel/src/xk_agent.c3`.
**Verification:** A debug `scenedump` command shows the exact token/context pack fed to the
model.

### Task 3.2: model-driven window actions
**Objective:** The char-GPT, prompted with the context pack, picks an action token from a
fixed grammar; `agentd` parses it into `SYS_AGENT_ACT` (open/close/focus/move/type).
**Files:** Modify `kernel/src/xk_agent.c3`, `kernel/src/xk_apps.c3`.
**Verification:** End-to-end: prompt the model → it opens/focuses/closes windows; journal
shows the loop. (Model may be fuzzy at first; grammar constrains to safe actions.)

### Task 3.3: planet/continuity snapshot
**Objective:** A one-shot `SYS_AGENT_SNAPSHOT` that marshals scene + VFS catalog +
running model context into FAT/VFS files (reuse `xk_fat.c3`) so state survives reboot.
**Files:** Modify `kernel/src/xk_agent.c3`, `kernel/src/xk_fat.c3`.
**Verification:** Reboot; agent reloads its snapshot and resumes its last session.

### Task 3.4: commit
**Verification:** `boot_verify.sh` passes; full loop demonstrated and screenshotted.
Commit `feat(ai): model-driven desktop control + rebooting continuity`.

---

## Phase 4 — Hardening, docs, ship

### Task 4.1: preemption/`iretq` audit on the new agent paths
Verify the new scheduler paths never iretq a crafted frame and long-lived agent state is
in module globals (golden rule). **Files:** `xk_sched.c3`, `xk_agent.c3`.
### Task 4.2: README + architecture doc
New `docs/ai-first.md` explaining the model runtime, agent ABI, scene graph, journal.
### Task 4.3: full test pass
`./build.sh`, `scripts/boot_verify.sh`, serial-console ISO path; commit `docs(ai): ship`.

---

## Files likely to change (overview)
- Create: `kernel/src/xk_tensor.c3`, `xk_model.c3`, `xk_llm.c3`, `xk_agent.c3`;
  `tools/mkweights.c3`, `tools/tensor_test.c3`; `user/agentd.asm`; `docs/ai-first.md`.
- Modify: `kernel/src/xk_alloc.c3`, `xk_kbd.c3`, `xk_mouse.c3`, `xk_wm.c3`,
  `xk_apps.c3`, `xk_sys.c3`, `xk_sched.c3`, `xk_uprog.c3`, `xk_umode.c3`, `xk_fat.c3`,
  `xk_shell.c3`; `README.md`.

## Validation strategy
- After every task: `./build.sh` (must stay green) then `scripts/boot_verify.sh`
  (desktop up, shell driven, screenshot). Keep the harness prefixing lowercase.
- Model/tensor math is validated with host-side freestanding C3 harnesses
  (`tools/tensor_test.c3`) before being trusted in-kernel — numeric equality asserted.
- New ring-3 syscall coverage exercised by extending the embedded `user/sys_prog.asm`.

## Risks, tradeoffs, open questions
- **Model fidelity on 256 MB + TCG is the hard constraint.** A realistic LLM won't fit;
  we deliberately target a tiny char/token GPT (few MB params) so it *runs* and is
  *genuinely generated*, not simulated. Open question: exact model size/context budget
  to keep the desktop, VFS, and agent all resident together — resolve in Task 1.3 by
  measuring actual heap use on the running system.
- **Integer-only inference cuts fidelity** but keeps us SSE/AVX-free (`#UD` rule).
- **Agent safety:** to avoid unbounded/unsafe actions, Phase 3 constrains the model to a
  fixed windowing-grammar token set and journals everything; full tool freedom is out of
  scope for a hobby OS.
- **Existing limitations inherited:** still one ring-3 process table generalization pending
  (`agentd` may need to coexist with `sys_prog.asm`; the current single-process constraint
  from the README must be lifted or worked around in Task 2.2). AHCI data path remains
  broken on QEMU — Phase 3 uses FAT PIO (working) for snapshots, not SATA.
- **"AI-first" vs hobby scope:** each phase is independently shippable and demonstrable;
  the architecture surfaces the OS to the model without gating existing milestones.