# Cocoa backend resurrection — porting map

Spec for executing the port of the pre-0.38 ObjC Cocoa backend into this
0.41-based tree, targeting macOS 10.5/10.6 PPC, compiled with FSF GCC
(no blocks, no ARC, fragile 32-bit NeXT ivar ABI).

This document pre-makes all judgment calls. **Execute it; don't redesign it.**
When an mpv API doesn't match what the old code expects and this document
doesn't cover it, do NOT guess: grep a working in-tree VO (`vo_x11.c`,
`context_glx.c`, `wayland_common.c`) for the current idiom, and if still
ambiguous, leave a `// XXX PORT:` comment and report it.

Companion appendices (already generated, with file:line detail):
- `port-notes/inventory-clang-isms.md` — every block/literal/subscript/property
- `port-notes/inventory-api-floor.md` — every >10.5/>10.6 API with fix per site

## 0. Already done (do not redo, do not "simplify")

Session of 2026-07-22 (Fable) wrote the app-side glue **from scratch** —
the old `osdep/macosx_application.m` / `macosx_events.m` / `macosx_menubar.m`
must NOT be resurrected; their replacements are:

| new file | replaces | notes |
|---|---|---|
| `osdep/mac/mainthread.{h,m}` | `dispatch_sync(main_queue, ^{})` pattern | `mp_mac_run_on_main(fn, ctx, sync)`; dispatch `_f` API on 10.6+, `performSelectorOnMainThread:` on 10.5 |
| `osdep/mac/app_objc.{h,m}` | `macosx_application.{m,h,_objc.h}` | Application class, `cocoa_main()` (NSApp on main thread, core on pthread, exit via `exit(r)` on core thread — the old model), `MPMenuKey`, `cocoa_register_menu_item_action()` |
| `osdep/mac/events_objc.{h,m}` | `macosx_events.{m,h,_objc.h}` | EventsResponder, keymap, `cocoa_put_key*()`, `cocoa_set_input_context()`, `cocoa_set_mpv_handle()`, media keys via NSSystemDefined (no MPRemoteCommandCenter) |
| `osdep/mac/menubar_objc.{h,m}` | `macosx_menubar.{m,h}` | compact menubar; full 831-line port is **optional phase E** |
| `osdep/mac/app_bridge.m` (edited) | — | non-Swift branch now only stubs `cocoa_init_cocoa_cb()` |
| `meson.build` (edited) | — | non-Swift cocoa builds compile the four new .m files + link ApplicationServices |

The threading design in these files is deliberate (including the
`terminate_cocoa_application()` + `exit(r)` race, taken from the old backend).
Leave it alone.

## 1. Resurrect the VO files

Source commit: `fc4db187d0^` (parent of "cocoa: remove OpenGL cocoa backend").

```
for f in video/out/cocoa_common.h video/out/cocoa_common.m \
         video/out/cocoa/events_view.h video/out/cocoa/events_view.m \
         video/out/cocoa/video_view.h video/out/cocoa/video_view.m \
         video/out/cocoa/window.h video/out/cocoa/window.m \
         video/out/cocoa/mpvadapter.h \
         video/out/opengl/context_cocoa.c; do
    mkdir -p $(dirname $f); git show fc4db187d0^:$f > $f
done
```

Include rewrites in every resurrected file:

| old include | new include |
|---|---|
| `osdep/macosx_application.h` | `osdep/mac/app_objc.h` (MPMenuKey, register fn) and/or `osdep/mac/app_bridge.h` (macos_opts, macos_conf) |
| `osdep/macosx_application_objc.h` | `osdep/mac/app_objc.h` |
| `osdep/macosx_events.h` / `_objc.h` | `osdep/mac/events_objc.h` |
| `osdep/macosx_compat.h` | `osdep/mac/compat_legacy.h` (new, see §3) |
| `osdep/threads.h` | unchanged (mp_mutex/mp_cond names — verify each use against current `osdep/threads-posix.h`) |

`struct macos_opts` drift: the old struct had `macos_title_bar_style`; the
current one (in `osdep/mac/app_bridge.h`) does not. Delete every reference
along with the title-bar styling code (it's 10.10+ NSVisualEffectView
cosmetics — see api-floor inventory — DELETE category).

## 2. Build wiring

In `meson.build`, extend the existing `gl-cocoa` block (~line 1175), which
already links OpenGL.framework:

```meson
if features['gl-cocoa']
    dependencies += GL
    if not features.get('swift', false)
        sources += files('video/out/cocoa_common.m',
                         'video/out/cocoa/events_view.m',
                         'video/out/cocoa/video_view.m',
                         'video/out/cocoa/window.m',
                         'video/out/opengl/context_cocoa.c')
    endif
endif
```

Register the context in `video/out/gpu/context.c`: add
`extern const struct ra_ctx_fns ra_ctx_cocoa;` and an entry in `contexts[]`
guarded by `#if HAVE_GL_COCOA`, placed **above** `ra_ctx_sdl` so auto-probing
prefers native Cocoa. (`HAVE_GL_COCOA` already exists via the feature dict.)

If fullscreen uses `SetSystemUIMode` (10.5 path, §4), add
`dependency('appleframeworks', modules: ['Carbon'])` in the same non-swift
branch. On 10.6 use `-[NSApplication setPresentationOptions:]` instead
(`#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060`).

## 3. New file: `osdep/mac/compat_legacy.h`

Resurrected files use 10.12-era event names; the 10.5/10.6 SDKs have the
legacy ones. Create a header mapping **modern → legacy**, e.g.:

```c
#pragma once
#import <Cocoa/Cocoa.h>
#include <AvailabilityMacros.h>
#if MAC_OS_X_VERSION_MAX_ALLOWED < 101200
#define NSEventTypeKeyDown        NSKeyDown
#define NSEventTypeKeyUp          NSKeyUp
#define NSEventModifierFlagShift  NSShiftKeyMask
#define NSEventModifierFlagControl NSControlKeyMask
#define NSEventModifierFlagOption NSAlternateKeyMask
#define NSEventModifierFlagCommand NSCommandKeyMask
#define NSEventMaskLeftMouseUp    NSLeftMouseUpMask
#define NSWindowStyleMaskTitled   NSTitledWindowMask
/* ...complete the list from port-notes/inventory-api-floor.md
   ("event constant renames" section) — every rename it lists,
   including NSEventType*, NSEventMask*, NSWindowStyleMask*,
   NSModalResponseOK -> NSOKButton. */
#endif
```

Include it from every resurrected `.m`/`.c` right after the Cocoa import.

## 4. API-floor fixes (per `inventory-api-floor.md`)

Pre-made decisions for the REDESIGN/REPLACE items:

- **Lion fullscreen (window.m)** — REDESIGN, do it as *phase D*, not first.
  Delete: `toggleFullScreen:` override, all `willEnter/didEnter/willExit/
  didExitFullScreen` delegate methods, `NSWindowCollectionBehaviorFullScreen*`,
  `NSWindowStyleMaskFullScreen`, fs-animation code (and the
  `macos-fs-animation-duration` handling becomes dead — leave the option, it
  just won't animate). Implement manual fullscreen: save the windowed frame,
  `setStyleMask:NSBorderlessWindowMask`, `setFrame:[screen frame]`,
  `setLevel:` above menubar; hide menubar/dock via `setPresentationOptions:`
  (10.6) / `SetSystemUIMode(kUIModeAllHidden, ...)` (10.5). Reverse to exit.
  The old pre-0.29 mpv window.m (`git log --oneline v0.28.2 -- video/out/cocoa/window.m`)
  had exactly this logic — crib from it rather than inventing.
  **Until phase D, make `vo_cocoa_fullscreen()` a no-op with an MP_WARN.**
- **HiDPI/backing APIs** (`backingScaleFactor`, `convertRectToBacking`,
  `setWantsBestResolutionOpenGLSurface:`) — DELETE; scale factor is always 1.0.
- **`kCGLPFAOpenGLProfile` / `kCGLOGLPVersion_3_2_Core`** in
  `context_cocoa.c` — DELETE the 3.2-core probe loop; keep only the legacy
  path (attrs without any profile attribute). Also delete the
  "deprecated, use vo=libmpv" MP_WARN in `cocoa_init`.
- **`NSEvent addLocalMonitorForEventsMatchingMask:`** (blocks-only API, used
  in `cocoa_common.m:356` only to clear `s->window_is_dragged` on mouse-up)
  — DELETE `cocoa_add_event_monitor`/`cocoa_rm_event_monitor` and instead
  clear the flag from the events view's/window's `mouseUp:` path.
- **Power management**: `IOPMAssertionCreateWithName` is 10.6+. Guard:
  10.6+ keeps the assertion calls; 10.5 calls `UpdateSystemActivity(UsrActivity)`
  periodically from the displaylink/swap path (cheap, classic).
- **`IONotificationPortSetDispatchQueue`** → `IONotificationPortGetRunLoopSource`
  + `CFRunLoopAddSource` on the main run loop (10.0+).
- **`convertRectFromScreen:`** (10.7+) → `convertBaseToScreen:`-based
  equivalent per inventory suggestion.
- Everything the inventory marks DELETE (`setAllowsAutomaticWindowTabbing:`,
  occlusion state, NSAppearance, etc.): delete, no guards.

## 5. De-blockify recipe (per `inventory-clang-isms.md`)

`cocoa_common.m` has `run_on_main_thread(struct vo *vo, void(^block)(void))`
plus 8 call sites and one `__block` variable. Mechanical transform:

```objc
// BEFORE
run_on_main_thread(vo, ^{
    s->cursor_visibility_wanted = visible;   // may use __block int r
    ...
});

// AFTER — one static fn + stack struct per call site
struct set_cursor_call { struct vo *vo; bool visible; int r; };
static void set_cursor_on_main(void *p) {
    struct set_cursor_call *c = p;
    struct vo_cocoa_state *s = c->vo->cocoa;
    ...
    c->r = ...;          // __block var becomes a struct field
}
...
struct set_cursor_call call = { vo, visible };
mp_mac_run_on_main(set_cursor_on_main, &call, true);  // sync, like dispatch_sync
```

Rules:
- Delete the old `run_on_main_thread` helper (`cocoa_common.m:118-125`).
- Every old call was `dispatch_sync` → use `sync=true` everywhere; the stack
  struct stays valid. Only use `sync=false` if the old code used
  `dispatch_async`, and then the ctx must be heap/static.
- `dispatch_once` → `pthread_once` (see `events_objc.m` for the idiom).
- `enumerateObjectsUsingBlock:` → `for (id x in array)` fast enumeration.
- Name the static fns after the call site (`<what>_on_main`).

## 6. GCC / fragile-ABI mechanicals (per `inventory-clang-isms.md`)

- **Ivars**: the 32-bit NeXT fragile ABI forbids ivars in class extensions /
  `@implementation`. Hoist every ivar from `@interface Foo ()` { ... } blocks
  in the resurrected files into the main `@interface` in the corresponding
  header. (Methods may stay in extensions; only ivars move.)
- **Literals**: `@[...]` → `[NSArray arrayWithObjects:..., nil]`;
  `@{...}` → `[NSDictionary dictionaryWithObjectsAndKeys:..., nil]` or,
  better, a plain C `switch`/array (see `mapTypeModifiers` in
  `events_objc.m`); `@(n)` → `[NSNumber numberWith...:n]`;
  container subscripting → `objectAtIndex:` / `objectForKey:`.
- **Dot syntax**: convert to bracket messages everywhere in resurrected files
  (10.5/10.6 SDK headers declare `-[NSEvent type]` etc. as methods, not
  properties, so GCC rejects `event.type`).
- **`@autoreleasepool`** → explicit `NSAutoreleasePool` alloc/drain (GCC
  support for the directive is uncertain; don't risk a build cycle).
- `@property`/`@synthesize` pairs are already complete tree-wide (verified);
  keep them, add nothing auto-synthesized.
- No `instancetype`, `NS_ENUM`, generics, nullability anywhere (verified
  absent — keep it that way).

## 7. mpv 0.37→0.41 API drift

- `struct ra_gl_ctx_params` → `struct ra_ctx_params` (moved to
  `video/out/gpu/context.h`). The cocoa context only sets `.swap_buffers` —
  compiles unchanged after the rename.
- `struct ra_ctx_fns`: field `.hidden` is gone (old code didn't set it);
  new field `.description` — set `"Cocoa/NSOpenGL (legacy)"`.
- `mpgl_load_functions(gl, getProcAddress, NULL, log)` — signature unchanged.
- `mp_event_drop_files()` no longer exists. The drag&drop handler in
  `events_view.m` must build an `NSArray` of path strings and call
  `[[EventsResponder sharedInstance] handleFilesArray:files]` (it already
  converts to the new `mp_event_drop_mime_data` internally).
- `vo->opts->field` direct reads still work (`struct vo` still has the
  mirrored `opts` pointer, `vo.h:507`). Verify the old file's
  `VOCTRL_VO_OPTS_CHANGED` handling compiles against current option field
  names (`fullscreen`, `ontop`, `ontop_level`, `border`, `WinID`,
  `hidpi_window_scale` — delete the hidpi one per §4).
- All VOCTRLs the old code handles still exist (verified:
  UPDATE_WINDOW_TITLE, KILL/RESTORE_SCREENSAVER, GET/SET_UNFS_WINDOW_SIZE,
  GET_FOCUSED, GET_DISPLAY_NAMES, GET_ICC_PROFILE, GET_AMBIENT_LUX,
  GET_DISPLAY_FPS, SET_CURSOR_VISIBILITY, FULLSCREEN, ONTOP, BORDER).
- Colorspace rework (`mp_colorspace` → `pl_color_space`) only matters if the
  old code touches `swapchain->color_space` — it doesn't; the ICC path goes
  through `VOCTRL_GET_ICC_PROFILE` returning a `bstr`, unchanged.
- present_sync is NOT required — the old displaylink-based vsync reporting
  can stay as-is.
- `mp_thread`/`mp_mutex` names: the old file is from the same threads.h era;
  verify each against `osdep/threads-posix.h` (both `mp_thread_create` and
  `mp_cond`/`mp_mutex` survive; fix any stragglers).

## 8. Execution order (each step must leave the tree compiling for
non-Darwin targets — Linux CI must stay green)

- **A**: §1 resurrect + §2 wiring + §3 compat header + include fixes.
  Goal: files in tree, meson knows them. (Nothing compiles them on Linux.)
- **B**: §4 floor fixes + §5 de-blockify + §6 mechanicals + §7 drift, with
  fullscreen stubbed (no-op + MP_WARN). Keep diffs vs the resurrected
  originals minimal and reviewable; don't reformat or restructure.
- **C**: user builds on PPC hardware; iterate on pasted GCC error logs.
  Expect: header-order issues, missed dot-syntax, missed renames.
- **D**: manual fullscreen (crib from v0.28.x window.m), power-management
  guards, ICC verification.
- **E** (optional): full menubar port onto `menubar_objc.m` (~85 dict
  literals → C tables; biggest purely mechanical job, see inventory).

## 9. Test plan (user, on hardware, after C)

1. `mpv --no-config file.mkv` — native window appears, video plays,
   `--gpu-context=cocoa` selected by auto-probe (check `-v` log).
2. THE original bug: OSC/keyboard/mouse responsive **during** playback.
3. Quit paths: `q`, Cmd-Q, window close button, `--frames=100` natural EOF;
   check `echo $?` propagates.
4. `--input-media-keys=yes` → play/pause key works.
5. Drag&drop file onto window; drag onto Dock icon (bundle).
6. Audio-only file → no Dock icon/menubar takeover (accessory policy).
7. `--vo=gpu` and `--vo=gpu-next` both on the cocoa context.
8. Regression: `--vo=sdl` and X11 build still work. NOTE: with NSApp now
   running the main loop, vo_sdl's own event pump may interact oddly —
   if it degrades, that's an accepted regression to document, not fix.
9. 10.5 build (`MAC_OS_X_VERSION_MIN_REQUIRED < 1060`): compiles, launches
   (exercises the performSelector path in mainthread.m and
   TransformProcessType in app_objc.m).

## 10. Known risks / open items

- GCC ObjC oddities not caught by inventories (e.g. protocol conformance
  strictness) — will surface as compile errors in step C; cheap to fix.
- `sendEvent:` override + compact menubar: Cmd-Q arrives via the
  kAEQuitApplication Apple Event (handled), not menu key equivalent — if
  Cmd-Q does nothing, check `performKeyEquivalent:` path first.
- The `-psn_` argument stripping and `mpv-bundle` detection assume the
  TOOLS/osxbundle wrapper naming; verify against this fork's mpv.app bundle
  script when building the .app.
- `--wid` embedding (`s->embedded` paths in cocoa_common.m): keep the code
  paths compiling but do NOT test/fix until the CLI experience works
  (phase 2 per the overall plan).
