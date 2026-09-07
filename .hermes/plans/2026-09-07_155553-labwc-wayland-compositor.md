# labwc (wlroots Wayland compositor) on xenOS — Implementation Plan

> **For Hermes:** use subagent-driven-development to implement phase-by-phase.
> This is a **program**, not a single feature. Each Phase ends in a green, verifiable
> milestone before the next starts. Cross-build recipes live in the repo's `scripts/`.
> Prior art (read first): `AGENTS.md`, `.hermes/plans/2026-08-31_173146-wayland-xfce4-display.md`
> (the original multi-month roadmap; Phase D.3 = "wlroots-based compositor" — labwc was
> named there but **zero labwc/wlroots code exists yet**).

**Goal:** Cross-build **wlroots + labwc** to shared musl and get **labwc running in-guest on
xenOS** — first headless (prove the stack boots), then **rendering visible composited output
nested on the existing kernel Wayland compositor** (`xk_wl.c3`) — with **zero GPU / no Mesa**.
This is the launchable first step toward the end-goal "Xfce desktop running on labwc".

**Architecture:** Two important facts make this tractable and set the strategy:
1. **labwc does NOT need OpenGL.** Built against a wlroots configured with **only the pixman
   software renderer** and launched with `WLR_RENDERER=pixman`, the whole
   EGL/GLES/Mesa/llvmpipe tree is unnecessary (verified upstream: wlroots `-Drenderers=`
   empty → composits via CPU only). xenOS has no GPU and only ~1–5 fps under TCG anyway, so
   the software path is the *correct* long-term renderer, not a stopgap.
2. **wlroots has a "wayland" backend** that runs the compositor as a *client of another
   compositor*. Pointing it at the existing kernel compositor (`/run/wayland-0`, already
   hosts GTK wayland clients) gives **visible labwc output with no new kernel display
   work** — labwc's whole desktop composites down to one xdg window on `xk_wl`.

**Tech stack:** C3 0.8.3 (kernel, unchanged except small syscall/ioctl gaps) · musl shared
cross-build (existing sysroot `/home/timo/crossmusl`) · wlroots 0.20.x (pixman renderer only) ·
labwc 0.9.x → later Xwayland + Xfce over it · QEMU TCG stdvga framebuffer.

---

## 0. Ground truth + strategic decisions (verified 2026-09-07)

**Already cross-built in `/home/timo/crossmusl/sysroot`** (shared `.so` + pkg-config present):
`wayland-client/server`, `wayland-protocols`, `xkbcommon`, `pixman`, **`libdrm`**, `glib`,
`cairo`(+`pangocairo`), `pango`, `libpng`, **`libxml2`**, `expat`, xcb / **`libxcb-util`**,
GTK3, zlib, harfbuzz, fontconfig (+ full Xfce/Xwayland staged rootfs from Phases F.1/F.2).

**Missing → must cross-build** (each small, see Phase 1):
- `xcb-util-wm` (`libxcb-ewmh`, `libxcb-icccm` + `.pc`) — labwc hard dep.
- `wayland-protocols` **bump to >= 1.39** (labwc's meson requires it; verify the staged one's
  version, presumably an older 1.3x from Phase D/E).
- (only if the libinput backend is wanted) `libinput`/`libevdev`/`libudev` — **SKIP for now**;
  build wlroots with backends `headless`(+`wayland`) only so `have_libinput_backend=false`
  and labwc's `libinput` dep becomes optional.

**Versions to pin (verify against labwc's `meson.build` at impl time):** wlroots **0.20.2** +
labwc release whose meson pins `['>=0.20.0','<0.21.0']` (0.9.x, e.g. **0.8.0/0.9.x**). If the
staged `libwayland-client/server` is < 1.22.90, bump wayland too (labwc needs `>=1.22.90`).

**Decision: near-term visible = NESTED, not top-level.** Steps:
- Phase 3 runs labwc with `WLR_BACKENDS=wayland WLR_RENDERER=pixman WAYLAND_DISPLAY=wayland-0`
  so its composited desktop appears as a window in the kernel compositor → **visibly verified
  "labwc works on xenOS"** with no kernel display changes. This also stress-tests `xk_wl`
  against a real wlroots client (it will need protocol surface wlroots uses that bare GTK
  didn't: cursor via `wl_shm`, seat handling, xdg_toplevel resize, subcompositor etc.). Fixing
  those gaps is part of the milestone.
- Phase 5 (long tail, optional) makes labwc **top-level on the framebuffer** via a hand-written
  minimal wlroots backend or a kernel KMS-lite path — this is where months of effort live; NOT
  required for "labwc works."

---

## Phase 1 — Cross-build the missing deps (`scripts/crossbuild_deps.sh`)

Add targets to the existing autotools/meson cross pattern (musl-gcc + `PKG_CONFIG_LIBDIR`
cross wrapper + `$INC/linux` stubs, see `scripts/crossbuild_deps.sh`, `crossbuild_shared.sh`,
and references `gtk3-crossbuild.md` / `xwayland-crossbuild.md` for the proven trap list:
never export `LD_LIBRARY_PATH`, `unset PKG_CONFIG_LIBDIR` for native tools, patchelf
`RPATH=$SYS/lib` into sysroot/bin tools, `make distclean` before shared reconfigure).

**Task 1.1 — xcb-util-wm.**
- Fetch `xcb-util-wm` (gitlab.freedesktop.org/xcb/util-wm), autotools: `CC=musl-gcc
  ./configure --host=x86_64-linux-musl --prefix=$SYS && make && make install`.
- Verify: `$SYS/lib/libxcb-ewmh.a`, `libxcb-icccm.a`, `$SYS/lib/pkgconfig/xcb-ewmh.pc`,
  `xcb-icccm.pc` exist.

**Task 1.2 — bump wayland / wayland-protocols.**
- Check `wayland-server.pc` version (`grep Version$`); if < 1.22.90, rebuild wayland 1.23.x
  shared (`-Ddefault_library=shared`) exactly as `crossbuild_shared.sh` does.
- Check `wayland-protocols.pc` >= 1.39; bump to 1.39+ if older (plain `meson setup` +
  `ninja -C build install`, headers+pc only).
- Verify: `pkg-config --modversion wayland-server wayland-protocols` against the cross
  PKG_CONFIG_LIBDIR.

**Task 1.3 — (stretch, only if a phase wants it) libinput/libevdev/udev.** Skip unless a later
phase chooses the libinput backend; headless+wayland backends don't need it.

**Gate:** `./scripts/test.sh` still green (this phase only adds cross libs, no kernel change).

---

## Phase 2 — Cross-build wlroots (pixman renderer only) + labwc

New script `scripts/crossbuild_labwc.sh` (mode `wlroots` / `labwc` / `all`), mirroring
`crossbuild_xwayland.sh`'s structure (separate per-package tarball fetch + meson cross build +
`ninja install` into `$SYS`, then stage `.so` + SONAME links into the rootfs).

**Task 2.1 — wlroots 0.20.x.**
- `meson setup build --cross-file=$WLCROSS` with `-Drenderers=` (empty → pixman only) and
  `-Dbackends=headless,wayland` (no drm/libinput → no udev/seatd/libliftoff needed),
  `-Dexamples=false`, `-Ddefault_library=shared`, `-Dxwayland=false` (X11 backend off).
- Pixman renderer needs `dependency('pixman-1')` (have it). The wayland backend needs
  `wayland-server`, `wayland-client`, `wayland-protocols`, `xkbcommon`.
- Cross-file: `c=musl-gcc`, `pkg-config` = the cross wrapper (`PKG_CONFIG_LIBDIR=$SYS/lib/pkgconfig`),
  `unset PKG_CONFIG_LIBDIR` around native `wayland-scanner` invocations if meson cross-resolves it.
- install `libwlroots.so.12` + headers + `wlroots-0.20.pc` into `$SYS`.
- Verify (host-loadable): a tiny wlroots-less smoke — `nm -D libwlroots.so.12 | grep
  wlr_backend_autocreate` and that it `LD_LIBRARY_PATH=$SYS/lib` loads under the host musl
  loader without glibc deps.

**Task 2.2 — labwc 0.9.x.**
- `meson setup build` with the same cross-file, `-Dxwayland=disabled` (Xwayland folded in a
  later phase over the already-staged Xwayland), `-Dlibsfdo=disabled`, `-Dicon=disabled
  -Dsvg=disabled` (drop librsvg), `-Ddefault_library=shared`.
- Deps it will resolve from `$SYS`: `wlroots-0.20`, `wayland-server`, `wayland-protocols`,
  `xkbcommon`, `xcb-ewmh`, `xcb-icccm`, `libxml-2.0`, `glib-2.0`, `cairo`/`pangocairo`,
  `libdrm`, `pixman-1`, `libpng`.
- install `labwc` into `$SYS/bin`.
- Verify host-loadable: `LD_LIBRARY_PATH=$SYS/lib $SYS/bin/labwc --version` prints a version →
  the binary links and its shared chain resolves on the host (same trick as the E3 `dynmain`).

**Task 2.3 — stage onto the ext4 rootfs.** Extend `scripts/stage_xfce_rootfs.sh` (or a new
`stage_labwc_rootfs.sh`) to copy: `bin/labwc`, `lib/libwlroots.so.*`, and the DT_NEEDED chain
it pulls (audit with musl `ldd`), plus a minimal `labwc/rc.xml` + `menu.xml` + an
`environment` file setting `WLR_RENDERER=pixman`. Re-run `build.sh` to merge into
`build/rootfs.ext4`, bump the ext4 block count (98304→ e.g. 131072) if it overflows.

**Gate:** staged `labwc` runs headless under the **host** musl loader: `cd / && (export
HOME=/root XDG_RUNTIME_DIR=/run WLR_BACKENDS=headless WLR_RENDERER=pixman;
LD_LIBRARY_PATH=$SYS/lib $SYS/bin/labwc)` starts (it will fail when it can't find a seat —
capture that it initialized the display, no undefined-symbol crash).

---

## Phase 3 — Run labwc in-guest (headless acceptance → visible nested)

Matching the proven pattern: boot the dynamic GTK app in-guest (`dynmain` at
`linux_dyn_rootfs`), launching labwc as the guest userspace process.

**Task 3.1 — guest process that execs labwc.** Add a small launcher (extend
`tools/e1/rsmain`-style `_start` or a `dynmain` variant) that sets the guest env
(`WAYLAND_DISPLAY=wayland-0`, `XDG_RUNTIME_DIR=/run`, `HOME=/root`, `WLR_BACKENDS=...`,
`WLR_RENDERER=pixman`) and `exec`s `labwc` from the rootfs. Kernel launch point: reuse the
`linux_dyn_rootfs`/static-main path in `xk_linux.c3` that already boots `dynmain`.

**Task 3.2 — headless first.** Boot with `WLR_BACKENDS=headless`; assert from serial:
`[labwc]` init log, `wl_display` created, `[wl]` wire activity on `/run/wayland-0`, process
stays alive (no `#UD`/hang). Acceptance = **the wlroots+labwc stack boots and runs its event
loop on xenOS**, host-parity with 3.1's gate.

**Task 3.3 — visible nested (the milestone).** Re-run with `WLR_BACKENDS=wayland`,
`WAYLAND_DISPLAY=wayland-0`. labwc (as a wayland *client*) connects to `xk_wl`, creates an
xdg_toplevel output, and composites. **Verify with a QEMU `screendump`** + pixel check
(same technique as the wl_shm surface milestone).
- Expected protocol gaps to close in `xk_wl.c3` (each boot-verified, commit separately):
  missing globals/interfaces wlroots binds (verify via `[wl]` wire trace): `wl_shm` cursor
  buffer, `wl_seat` capabilities + keymap already present (aafac3d), any `xdg_*` ops beyond
  current GTK path, `wl_surface`/damage/frame re-emission for a compositor client, resize.
  Ground rule from AGENTS.md: wlroots/labwc event loop = **epoll over eventfd/timerfd/
  signalfd** — confirm `epoll*`, `eventfd`, `timerfd_create` are in the syscall table
  (eventfd+epoll are done; **timerfd/signalfd may be the next unblock**).
- IMPORTANT context: current guest model is **one ring-3 process at a time/synchronous** —
  labwc as a single process (compositor + client in one addr space, no fork needed yet) is
  fine; do NOT require multi-process for this milestone.

**Gate:** `boot_verify.sh` + screendump shows labwc's default desktop (solid background +
window decorations) as a live region on the kernel-composited screen. Screenshot committed.
AGENTS.md "Incomplete/Experimental" updated: **labwc runs in-guest, software-rendered, nested
on the kernel compositor.**

---

## Phase 4 — Input routing + a client window (valuable polish, optional-ish)

Wire the kernel PS/2 mouse/keyboard → `xk_wl` wl_seat events so labwc's nested output gets
pointer/keyboard. Use the existing `wl_seat` emitters (Phase D `wl_seat`, aafac3d keymap).
Acceptance: a GTK wayland client window renders *inside* labwc's nested output (labwc
manages it as a client), and mouse-drive over it shows in screendump. This proves
"windows on labwc on xenOS," not just the empty desktop.

---

## Phase 5 (LONG TAIL — separate plan, do NOT start until 3.3 is green)

Make labwc **top-level on the framebuffer** (displace/replace `xk_wl` as the display server):
- Option A (recommended): a hand-written minimal **wlroots backend** (`wlr_backend_impl`) that
  exposes one output backed by a `wl_shm`/`MAP_SHARED` buffer the kernel maps/reads and blits
  to VRAM (`fb_present`). Renders via pixman → no GPU. Kernel change: expose the fb as a
  `MAP_SHARED`-able region + a present ioctl.
- Option B: kernel "KMS-lite": guest mmaps VRAM directly, labwc writes via the backend.
Then: **Xfce session over labwc**: Xwayland (already cross-built, F.1) as a labwc child +
xfce4-session/panel/desktop (already staged, F.2) over Xwayland/wayland.
This is the original roadmap's Phase D.3→F path; its full kernel A/F gaps (multi-process
fork+exec, evdev `/dev/input/event0`, DRM ioctls) remain the hardest work in the project.

---

## Risks, tradeoffs, open questions

- **Kernel is single-process userland (synchronous) right now.** labwc is ONE process, so the
  nested milestone works without multi-process. But labwc will try things (e.g. reading
  `/proc`/`/sys`, `gethostname`, `getpwnam`) — expect a `[linux] unimplemented syscall nr=`
  whack-a-mole like every prior userspace milestone; fix as surfaced.
- **xcursor config / XKB data**: labwc needs a valid `rc.xml` + XKB keymap data — the kernel
  compositor's XKB shutdown issue (GDK "Failed to create XKB context") applies; stage real
  XKB into the rootfs (`cp -rL /usr/share/xkeyboard-config-*`, per xenos-os-dev) before 3.3.
- **Performance**: pixman software compositing + TCG = single-digit fps. Acceptance is
  *correct visible frames + responsive input*, not smoothness (project-wide rule).
- **Nested vs top-level**: nesting forever is wrong for a real desktop; Phase 5 is the real
  end-game. The nested milestone is the *fastest honest proof labwc runs*, and it forces the
  protocol + syscall completeness that Phase 5 needs regardless.
- **wlroots version churn**: pin the exact wlroots↔labwc pair from labwc's meson.build; do not
  chase master.

## Acceptance criteria (the "done" list)

1. `xcb-util-wm` + `wayland-protocols>=1.39` cross-built; `wlroots` (pixman-only) + `labwc`
   cross-built to shared musl (`scripts/crossbuild_labwc.sh`).
2. Staged on the rootfs; `labwc` host-loadable under the musl loader.
3. **labwc boots in-guest** headless (serial `[labwc]`/`[wl]` evidence, no crash/hang).
4. **labwc renders visibly nested** on the kernel compositor (screendump + pixel check).
5. (Phase 4) A GTK client window renders inside labwc's output with input.
6. AGENTS.md + skill reference updated; each step committed; `boot_verify.sh` green;
   `gh` PRs land on `xenOS-AI/xenOs` master.

## Execution order (recommended)

Phase 1 → 2 → 3.2 → 3.3 → 4, then stop and reassess before Phase 5. Phase 5 is explicitly out
of scope for "get labwc to work" unless the user asks to go to the top-level/framebuffer goal.
