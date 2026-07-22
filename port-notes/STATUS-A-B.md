# Cocoa port — phases A & B: what was done

Status after executing COCOA-PORT-PLAN.md phases A and B. Phase C is the
on-hardware GCC build (iterate on error logs); phase D is manual fullscreen +
power-management 10.5 guards + ICC verification.

## Phase A — resurrect + wire (tree compiles on Linux; nothing compiles the
new .m files there)

- Resurrected 10 files from `fc4db187d0^`:
  `video/out/cocoa_common.{h,m}`, `video/out/cocoa/{events_view,video_view,
  window}.{h,m}`, `video/out/cocoa/mpvadapter.h`,
  `video/out/opengl/context_cocoa.c`.
- Include rewrites: `osdep/macosx_events*.h` → `osdep/mac/events_objc.h`;
  `osdep/macosx_application*.h` → `osdep/mac/app_objc.h`;
  context_cocoa.c → `osdep/mac/app_bridge.h` (for `macos_conf`/`struct macos_opts`).
- NEW `osdep/mac/compat_legacy.h`: maps 10.12-era AppKit enum names
  (NSEventType*, NSEventModifierFlag*, NSEventMask*, NSWindowStyleMask* incl.
  the `NSWindowStyleMask` *type*, NSModalResponse*) back to legacy 10.5 names,
  guarded by `#if MAC_OS_X_VERSION_MAX_ALLOWED < 101200`. Included from every
  resurrected .m right after the Cocoa import.
- meson.build: extended the `gl-cocoa` block to add the 4 .m files +
  context_cocoa.c in the `not swift` branch only.
- video/out/gpu/context.c: `extern ... ra_ctx_cocoa;` + `#if HAVE_GL_COCOA`
  entry in `contexts[]` placed above `ra_ctx_sdl`.

## Phase B — floor fixes, de-blockify, mechanicals, drift (fullscreen stubbed)

De-blockify (§5): deleted `run_on_main_thread`; the 7 block call sites became
static `*_on_main(void *p)` functions invoked through
`mp_mac_run_on_main(fn, ctx, sync=true)`. `__block int r` in `vo_cocoa_control`
became a `struct control_call` out-field. `vo_cocoa_config_window` split into
`_on_main` body + thin wrapper. Event monitor (`addLocalMonitor...`, blocks-only)
deleted; `window_is_dragged` now cleared from the events view's mouseUp path via
new `-[MpvCocoaAdapter clearDrag]`.

Floor fixes (§4):
- HiDPI: all `convertRect{To,From}Backing:`, `convertPointToBacking:`,
  `backingScaleFactor`, `setWantsBestResolutionOpenGLSurface:` deleted / made
  identity (scale is always 1.0). `mpv_backing_scale_factor()` macro = 1.0.
  `hidpi_window_scale` reads dropped (option field still exists, just unused).
- `convertRectToScreen:`/`convertRectFromScreen:` (10.7) → point-based
  `convertBaseToScreen:`/`convertScreenToBase:` (10.0-safe; size unchanged).
- context_cocoa.c: deleted the 3.2-core CGL profile probe (`kCGLPFAOpenGLProfile`,
  `CGLOpenGLProfile`, `kCGLOGLPVersion_*`); single legacy pixel-format path.
  `kCGLPFASupportsAutomaticGraphicsSwitching` (10.6) `#define`d to a benign
  10.5-safe attr when building on the 10.5 SDK. Removed the "use vo=libmpv"
  MP_WARN.
- Light sensor: `IONotificationPortSetDispatchQueue` → run-loop-source
  (`IONotificationPortGetRunLoopSource` + `CFRunLoopAddSource` on main run loop).
- `[NSWindow setRestorable:]` (10.7) guarded `#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1070`.
- Fullscreen: **stubbed** — `vo_cocoa_fullscreen()` is a no-op + MP_WARN. The
  entire Lion native-FS path was deleted from window.m (`toggleFullScreen:`
  override, `setToFullScreen`/`setToWindow`, the NSWindowDelegate Lion
  fullscreen protocol, `NSWindowStyleMaskFullScreen`,
  `NSWindowCollectionBehaviorFullScreenPrimary`, `setPresentationOptions:`,
  `windowDidChangeBackingProperties:`) and the adapter's notification-variant
  FS methods. `-calculateWindowPositionForScreen:` retained for phase D.

Mechanicals (§6):
- Literals `@[...]` → `[NSArray arrayWith...]` (events_view.m).
- Dot-syntax → bracket messages across all resurrected files.
- `@implementation MpvVideoWindow { ivars }` hoisted into window.h @interface
  (fragile 32-bit NeXT ivar ABI forbids ivars in @implementation).
- No `@autoreleasepool` present (already MRC `NSAutoreleasePool`).
- @property/@synthesize pairs KEPT per plan (not converted to manual accessors).

Drift (§7):
- `vo_calc_window_geometry2` → `vo_calc_window_geometry` (0.41 8-arg signature).
- `struct ra_gl_ctx_params` → `struct ra_ctx_params`; added `.description =
  "Cocoa/NSOpenGL (legacy)"` to `ra_ctx_cocoa`.
- Precise-scroll path (`hasPreciseScrollingDeltas` 10.7 / `scrollingDelta*`
  10.6) dropped; `scrollWheel:` always uses `deltaX`/`deltaY` (10.0).

## Post-review fixes (correctness review of A+B)
- `cocoa_common.m` `set_regular_activation_policy_on_main`: guarded the
  10.6+ `-setActivationPolicy:` behind `#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060`
  with a `TransformProcessType(kProcessTransformToForegroundApplication)` 10.5
  fallback (+ `ApplicationServices` include under the same guard), mirroring
  `set_activation_policy()` in `osdep/mac/app_objc.m`. Was an unguarded 10.5
  compile break. ApplicationServices is already linked by the app-glue non-swift
  meson branch, so no meson change was needed.
- `context_cocoa.c`: CGL pixel-format fallback loop guard `> 2` → `> 1` so the
  two-step fallback (drop auto-graphics-switching, then drop offline-renderers,
  keeping kCGLPFAAccelerated) matches the original 6-attr behavior after the two
  profile attrs were removed.

Open accepted risk (per plan §6, surfaces in phase C if the toolchain rejects
it): class-extension `@property`+`@synthesize` in window.m/events_view.m
synthesize ivars in the .m — the plan pre-decided to keep these.

## Deferred to phase C/D (not bugs)
- Power management: `IOPMAssertionCreateWithName` (10.6+) still used
  unconditionally — fine on 10.6, needs the 10.5 `IOPMAssertionCreate` fallback
  in phase D.
- `SetSystemUIMode` / Carbon linkage for 10.5 fullscreen: phase D (fullscreen
  is stubbed now, so no Carbon dep added yet).
- Any GCC ObjC strictness (protocol conformance, synthesized-ivar-under-fragile-
  ABI) surfaces as phase-C compile errors.
