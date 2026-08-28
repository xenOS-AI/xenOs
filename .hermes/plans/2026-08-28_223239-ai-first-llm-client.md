# xenOS "AI-First" — External-LLM Client Architecture

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Make xenOS connect to an external Large-Language-Model provider (OpenCode Go,
ChatGPT/OpenAI, or any OpenAI-compatible API) as a first-class OS client. The initial
deliverable is the tiny config surface the user asked for — **model name, endpoint, and
token** — plus the provider-agnostic client plumbing that consumes it. "AI-first" here
means the OS ships an agent client subsystem designed to talk to an LLM API, not to embed
a model.

**Architecture:** An `ai` subsystem with three layers:
1. **Provider config** — a small FAT-stored config file (`AI.CFG`) holding `model`,
   `endpoint` (base URL), and `token`; validated and parsed at boot into kernel structs.
2. **A provider-agnostic client API** — a single C3 interface that renders an
   OpenAI-compatible `chat/completions` request (model name, prompt/messages) and parses
   the returned completion. The provider adapter is just a URL + auth header + JSON, so
   swapping OpenAI ↔ OpenCode Go ↔ any compatible gateway is only config.
3. **Transport** — an HTTP/JSON client over a from-scratch network stack (see the big
   dependency below).

**Tech Stack:** C3 (freestanding, `--x86cpu=baseline --x86vec=none`), NASM, GNU ld, QEMU
(qemu64, TCG). No libc in-kernel. Existing components: `xk_fat.c3` (FAT16 files), `int
0x80` syscall gate, ring-3 process launch (`xk_umode.c3`), `xk_shell.c3`, own VESA WM.
No NIC driver or TCP/IP stack exists yet — building the transport is the heavy lift.

---

## Scope decision (from the request)

> "For now we just need model name, endpoint and token."

So the near-term deliverable is **Phase 0 + Phase 1 below**: a config format the OS reads,
and a client interface whose *contract* is fully specified so the moment transport lands,
it works. Building the full network/HTTP/TLS stack is a large, separate effort; we phase
it and keep the client API independent of transport so nothing is re-done.

---

## Phase 0 — Provider config + validation (the "model / endpoint / token" ask)

Goal: xenOS reads, validates, and exposes a provider configuration. No network needed.

### Task 0.1: `AI.CFG` format + loader
**Objective:** Define and parse a trivial config. Lines: `model=<name>`,
`endpoint=<base url>`, `token=<token>`. Stored as a real file on the FAT16 volume (reuse
`tools/mkfat.c3` to place a default `AI.CFG` in `build/fat.img`).
**Files:**
- Create `kernel/src/xk_ai_cfg.c3` (parser + struct `AiCfg { model[..], endpoint[..], token[..] }`).
- Modify `tools/mkfat.c3` (seed `AI.CFG` with a placeholder — no secret checked in).
- Modify `kernel/src/xk_core.c3`/`xk_main.c3` (mount + load at boot).
**Verification:** `aistatus` shell builtin prints parsed model/endpoint and *masked*
token (`tok····4ab1`) + "OK"/"MISSING" per field.

### Task 0.2: validation rules
**Objective:** Reject an unparseable/missing/incomplete config at boot with a clear serial
message; the `ai` subsystem reports a defined error code instead of failing silently.
**Files:** Modify `kernel/src/xk_ai_cfg.c3`.
**Verification:** Boot with a bad `AI.CFG` → boot_verify.sh sees the error line; with the
good one it sees `OK`.

### Task 0.3: `aiconfig` shell command to set/update at runtime
**Objective:** `aiconfig model <name>`, `aiconfig endpoint <url>`,
`aiconfig token <token>`, `aiconfig show` (masked) — writes `AI.CFG` back through the
existing FAT write path. This is the user-facing "point the OS at a provider" surface.
**Files:** Modify `kernel/src/xk_shell.c3`, `kernel/src/xk_ai_cfg.c3`.
**Verification:** Update fields, reboot, `aicfg show` reflects them (persist via FAT).

### Task 0.4: commit
**Verification:** `./build.sh` + `scripts/boot_verify.sh` pass. Commit
`feat(ai): provider config (model/endpoint/token) + shell surface`.

---

## Phase 1 — Provider-agnostic client contract (no transport yet)

Goal: fully specify and implement the request/response layer so any transport can slot in.
HTTP/TLS/networking is deferred (Phase 2).

### Task 1.1: request builder
**Objective:** A single C3 function
`build_chat_request(cfg, prompt, user_buf, user_len) -> http_frame_id` that lays out the
OpenAI-compatible POST body:
`{ "model":"<cfg.model>", "messages":[{ "role":"user", "content":"<prompt>" }] }`,
plus the expectation header `Authorization: Bearer <cfg.token>` and `Content-Type:
application/json`. Transport-independent (writes into a bounded buffer). Remembers
`Content-Length`.
**Files:** Create `kernel/src/xk_ai_client.c3`.
**Verification:** A host-side freestanding C3 tool (`tools/ai_req_test.c3`) feeds a prompt
+ a fake cfg and asserts the exact JSON bytes of the frame.

### Task 1.2: response parser
**Objective:** Parse a `chat/completions` response:
`choices[0].message.content`. This is the one field the agent needs. Token-by-token UTF-8
safety + a bounded non-UTF8 fallback.
**Files:** Modify `kernel/src/xk_ai_client.c3`.
**Verification:** `tools/ai_req_test.c3` feeds representative JSON and asserts the extracted
content string byte-for-byte.

### Task 1.3: provider adapter seam
**Objective:** Define the transport interface as a function-pointer `alias`
(`AiTransport = fn int(AiRequest*, AiResponse*)`) so the client calls one hook and swap
strategies (loopback, e1000, host-bridge) later without touching the client.
**Files:** Modify `kernel/src/xk_ai_client.c3`.
**Verification:** The client complex compiles with a stub transport that returns a canned
response; a `ai test` builtin calls it and prints the canned reply (proves the full
pipeline minus real I/O).

### Task 1.4: commit
**Verification:** `boot_verify.sh` green; `ai test` prints the canned completion.
Commit `feat(ai): provider-agnostic chat client contract (request/response/adapter seam)`.

---

## Phase 2 — Transport: the network stack and HTTP/JSON on the wire (big lift)

Goal: get bytes from the guest to the provider. This is the genuinely hard phase and the
largest unknown — flagged up front.

### The dependency (honest framing)
xenOS has **no NIC driver, no TCP/IP, no TLS, no HTTP client**. Reaching `endpoint` means
building from scratch, at minimum:
- **NIC driver** — QEMU offers an easy target: `e1000` or `virtio-net`. From-scratch DMA
  ring driver (compare to the existing AHCI/SATA work, which also stalled on QEMU DMA).
- **Ethernet → ARP/IP** — ARP resolution and a minimal IPv4/IP/UDP-family subset.
- **TCP over the host bridge** — map the provider's hostname/IP; a minimal TCP client
  (SEQ/ACK, a few retransmits) is a serious but tractable from-scratch milestone.
- **HTTP/1.1** — a request/respond client. Fits Phase 1's `AiTransport` seam.
- **TLS** — the *real* blocker. `chat/completions` endpoints are HTTPS-only; hand-rolling
  TLS (handshake + cert validation, no borrowable code) is a very large project.

### Task 2.1: pick a transport path and confirm reachability
**Objective:** Before coding, verify in QEMU that the guest can open a plaintext TCP
connection to a host-routed service and pull bytes (proves the NIC/DMA/IP/TCP skeleton
works before TLS is attempted). Use `-netdev user` / `-net nic,model=…` port-forward a
*plaintext* local mock endpoint on the host (`tools/ai_mock.c3` serving `/chat/completions`
over raw TCP). This de-risks the whole phase.
**Files:** Infrastructure scaffolding; `tools/ai_mock.c3`.
**Verification:** From the guest, connect to the mock and receive a canned completion
(end-to-end client over the new stack, no TLS yet).

### Task 2.2 → 2.N: build the stack in order (each a sub-plan)
1. e1000/virtio-net DMA driver (`xk_net.c3`).
2. ARP + IPv4 + UDP/client TCP (`xk_ip.c3`, `xk_tcp.c3`).
3. HTTP/1.1 client filling `AiTransport` (`xk_http.c3`).
4. **TLS decision point** — see open questions. Options: implement a minimal TLS 1.2
   handshake + AES-GCM reader (**major** milestone), or keep Phase 2 working against a
   local plaintext endpoint / host TLS-terminating proxy while TLS is a later milestone.
Commit `feat(net): e1000 + TCP + HTTP over host bridge (mock provider)`.

---

## Phase 3 — Agent loop on top of the client

Goal: turn the transport-backed client into an actual "AI-first" OS feature.

### Task 3.1: `ai chat "<prompt>"` shell → provider → print reply
**Objective:** End to end: read prompt from the shell, build request, send via transport,
parse, echo the completion.
**Files:** Modify `kernel/src/xk_shell.c3`, `kernel/src/xk_ai_client.c3`.
**Verification:** `ai chat "say hello"` returns the provider's text under QEMU.

### Task 3.2: ring-3 agent process (`agentd`)
**Objective:** A ring-3 program owning an agent session, calling the LLM through new
`int 0x80` agent syscalls (`SYS_AI_PROMPT`, `SYS_AI_RESPONSE`) — reuse the distinct-CR3
launch pattern from `xk_umode.c3`.
**Files:** Create `user/agentd.asm`; modify `xk_sys.c3`, `xk_uprog.c3`, `xk_umode.c3`.
**Verification:** `ps` shows `agentd`; it round-trips a prompt and prints the reply.

### Task 3.3: tool/action grammar (safe subset) + journal
**Objective:** Constrain the model to a fixed action grammar (open/focus/close/type a
window) parsed into structured WM calls; journal every action ("audit by design", like
Phase 2 of my first draft).
**Files:** Create `kernel/src/xk_agent.c3`; modify `xk_wm.c3`, `xk_apps.c3`, `xk_shell.c3`.
**Verification:** "open a clock window" from `ai chat` produces the window; `journal`
lists the action. Commit `feat(ai): agent process + safe action grammar`.

---

## Files likely to change (overview)
- Create: `kernel/src/xk_ai_cfg.c3`, `xk_ai_client.c3`, `xk_net.c3`, `xk_ip.c3`,
  `xk_tcp.c3`, `xk_http.c3`, `xk_agent.c3`; `tools/ai_req_test.c3`, `tools/ai_mock.c3`;
  `user/agentd.asm`; `docs/ai-first.md`.
- Modify: `kernel/src/xk_core.c3`, `xk_main.c3`, `xk_shell.c3`, `xk_sys.c3`,
  `xk_uprog.c3`, `xk_umode.c3`, `xk_wm.c3`, `xk_apps.c3`, `xk_fat.c3`;
  `tools/mkfat.c3`; `README.md`.
- `AI.CFG` seeded into `build/fat.img` by `mkfat.c3` (placeholder token only, no secrets
  in git).

## Validation strategy
- After every task: `./build.sh` then `scripts/boot_verify.sh` (desktop up, shell driven,
  screenshot); keep harness words lowercase.
- Request/response layers are proven by host-side freestanding C3 harnesses
  (`tools/ai_req_test.c3`) asserting exact JSON bytes — before any kernel/network risk.
- Transport de-risked against a local plaintext mock (`tools/ai_mock.c3`) over a QEMU
  port-forward before real HTTPS is attempted.

## Risks, tradeoffs, open questions
- **The real blocker is TLS on HTTPS providers.** OpenAI / OpenCode Go are HTTPS-only, and
  hand-rolling TLS from scratch is a major project with no borrowed code. Open question to
  resolve in Phase 2: (a) implement minimal TLS 1.2 + AES-GCM (large), or (b) for now run
  against a local host-side endpoint/TLS-terminating proxy over `-netdev user`
  (fastest true end-to-end, but not public-Internet-ready). Recommend (a) as a later
  milestone, (b) as the shippable demo.
- **No NIC stack exists yet** — Phase 2 is a from-scratch networking project in its own
  right (the AHCI DMA path on QEMU has already proved flaky; DMA-to-guest via NIC may hit
  similar ground, so Phase 2 starts with a reachability spike).
- **Credential handling:** the token is stored plaintext on the FAT image. For a hobby OS
  this is acceptable; note it. Never commit a real token — `mkfat` seeds a placeholder.
- **Provider drift:** the OpenAI-compatible `chat/completions` shape covers OpenAI and most
  gateways; exotic schemas are a config/parser tweak inside `xk_ai_client.c3`, not an
  architecture change.
- **Ring-3 generalization:** `agentd` may need to run alongside the existing single ring-3
  program (`sys_prog.asm`); the README's one-process constraint must be lifted in Phase 3.
- **Per-task commits** every task so each phase is independently demonstrable.