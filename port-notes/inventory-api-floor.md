# mpv Cocoa/AppKit API-Floor Audit — Porting to macOS 10.5/10.6 (PPC/Rosetta, 32-bit)

Scope: all `.m`, `.h`, `.c` files under `old_cocoa/` (osdep/, video/out/, video/out/cocoa/,
video/out/opengl/). Source is mpv 0.37-dev, originally targeting macOS 10.8+.

Target: macOS 10.5 Leopard (PPC/Rosetta, 32-bit) and macOS 10.6 Snow Leopard (32/64-bit Intel).
No Metal. OpenGL legacy/compatibility profile only (no core profile — that's 10.7+). AppKit of
the 10.5/10.6 era.

Legend for **Severity**:
- **DELETE** — feature is meaningless on PPC-era hardware/OS, just remove it.
- **GUARD** — keep the code, but wrap in a runtime/compile-time version check with a fallback.
- **REPLACE** — needs a 10.5/10.6-era API substituted in; substitute named below.
- **REDESIGN** — needs real structural rework (e.g. Lion fullscreen has no equivalent primitive
  pre-10.7 and must be reimplemented from scratch).

No `@available`/`__builtin_available` or `MAC_OS_X_VERSION_*` guards exist anywhere in this
codebase today — every item below is currently unconditional.

---

## 1. Lion-style fullscreen (`toggleFullScreen:` mechanism) — REDESIGN, largest item

This is the single biggest porting problem in the tree. mpv's `MpvVideoWindow` (window.m) is
built entirely around the AppKit Lion fullscreen APIs (`NSWindow` `NSWindowDelegate`
full-screen protocol), which do not exist prior to 10.7. There is no shim; this must be
reimplemented as manual "fake fullscreen" (borderless window resized to cover the screen),
which is exactly what the `else` branches of this code already do for the *non-native*
(`wantsNativeFullscreen == NO`) path — that's the one to keep as the *only* path pre-10.7.

| File:Line | API | Introduced | Suggested fix | Severity |
|---|---|---|---|---|
| `video/out/cocoa/window.m:62` | `NSWindowCollectionBehaviorFullScreenPrimary` | 10.7 (Lion) | `#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1070` guard; omit entirely pre-10.7 (constant doesn't exist in the 10.6 SDK headers, won't compile) | GUARD (compile-time only; no runtime behavior to preserve) |
| `video/out/cocoa/window.m:80` `-toggleFullScreen:` (override) | `NSWindow -toggleFullScreen:` | 10.7 | Rename mpv's method (it currently *overrides* the AppKit Lion selector); on 10.5/10.6 there is no base implementation to override, so this becomes an ordinary custom method invoked directly from `vo_cocoa_fullscreen()` — no `[super toggleFullScreen:]` call is possible | REDESIGN |
| `video/out/cocoa/window.m:110` | `[super toggleFullScreen:sender]` | 10.7 | Delete this call path entirely; force `wantsNativeFullscreen` to always be NO on 10.5/10.6 (i.e. hardcode `--native-fs=no` behavior) | REDESIGN |
| `video/out/cocoa/window.m:121,137` | `NSWindowStyleMaskFullScreen` | 10.7 (constant `NSFullScreenWindowMask` originally; renamed `NSWindowStyleMaskFullScreen` in 10.12 headers, both post-10.6) | Delete this style-mask bit on 10.5/10.6; there is no "OS-tracked fullscreen" window style bit pre-Lion. Fullscreen must be simulated purely via borderless style + `setFrame:` to screen bounds (already what `setToFullScreen`'s non-native branch does via `NSWindowStyleMaskBorderless`) | REDESIGN |
| `video/out/cocoa/window.m:155-163` `customWindowsToEnterFullScreenForWindow:` / `customWindowsToExitFullScreenForWindow:` | 10.7 (`NSWindowDelegate` Lion fullscreen protocol) | 10.7 | Delete — these delegate methods are only ever called by AppKit's native fullscreen machinery, which won't exist | DELETE |
| `video/out/cocoa/window.m:166,168` `startCustomAnimationToEnterFullScreenWithDuration:` / exit variant | 10.7 | 10.7 | Delete — same Lion fullscreen delegate protocol | DELETE |
| `video/out/cocoa/window.m:170-203` `windowDidEnterFullScreen:`, `windowDidExitFullScreen:`, `windowWillEnterFullScreen:`, `windowWillExitFullScreen:`, `windowDidFailToEnterFullScreen:`, `windowDidFailToExitFullScreen:` (as `NSNotification`-driven delegate callbacks) | 10.7 (the *notifications* `NSWindowWillEnterFullScreenNotification` etc. are Lion-only; AppKit never posts them pre-10.7) | 10.7 | These methods will simply never fire pre-10.7 since AppKit never sends the notifications. Keep the method bodies only as manually-invoked helpers from the non-native fullscreen path (which they already partly are, called directly from `setToFullScreen`/`setToWindow`); delete the notification-delegate declarations/expectation of automatic invocation | REDESIGN |
| `video/out/cocoa_common.m:849` `[s->window toggleFullScreen:nil]` | 10.7 | 10.7 | Replace call site with a direct custom method (e.g. `-mpvToggleFullScreen:`) once `toggleFullScreen:` is no longer overriding a real AppKit method | REDESIGN |
| `osdep/macosx_menubar.m:33` `NSFullScreenMenuItemEverywhere` user-default key | 10.7 (only meaningful with Lion fullscreen menu item) | 10.7 | DELETE — harmless no-op on 10.5/10.6 (just sets an unused NSUserDefaults key), but should be removed/`#if`-guarded for clarity since it documents intent that doesn't apply | DELETE |
| `video/out/cocoa_common.m:127-134` `queue_new_video_size` / `MpvWindowUpdate` — depends on window sized via fullscreen frame math | n/a (own code) | — | Verify the borderless-manual-fullscreen path (`setToFullScreen` else-branch) is exercised as the *only* path; it already looks 10.5-safe by itself (uses `setFrame:display:`, `NSWindowStyleMaskBorderless`) aside from the `NSWindowStyleMaskFullScreen` bit noted above | REDESIGN (integration, not new code) |

**Net recommendation:** Strip out the entire Lion `NSWindowDelegate` fullscreen protocol
conformance and the `toggleFullScreen:` override. Keep only the pre-existing "else" /
non-native manual fullscreen logic (borderless window + `setFrame:` to screen frame,
`NSApp setPresentationOptions:` swapped for `SetSystemUIMode` — see §3), and always take that
branch regardless of the `native_fs`/`wantsNativeFullscreen` option on 10.5/10.6 builds.

---

## 2. HiDPI / Retina / backing-store scaling — DELETE (hardware never has HiDPI)

PowerPC and early Core Duo/Core 2 Duo Macs running 10.5/10.6 never shipped Retina displays;
`backingScaleFactor` is always `1.0` and the backing-store coordinate APIs are all 10.7+
(introduced with Retina support in Lion / the 10.7 SDK, some as design conveniences that were
backported to 10.6.8 for compatibility but **not present in the 10.5 SDK**). Treat all of the
following as: functionally no-ops on this hardware, but must compile.

| File:Line | API | Introduced | Suggested fix | Severity |
|---|---|---|---|---|
| `video/out/cocoa_common.m:612` `[s->video setWantsBestResolutionOpenGLSurface:YES]` | 10.7 (`NSOpenGLView`/`NSView` HiDPI opt-in; also n/a since no `NSOpenGLView` used here, but selector exists on `NSView` from 10.7) | 10.7 | Delete the call entirely (`#if` out) — no HiDPI surfaces exist on this hardware | DELETE |
| `video/out/cocoa_common.m:711` `[s->current_screen backingScaleFactor]` | 10.7 | 10.7 | Replace with hardcoded `1.0` (or a helper `#define mpv_backing_scale_factor() 1.0`) | DELETE (replace call with constant `1.0`) |
| `video/out/cocoa_common.m:132,594,708,875,884` `convertRectFromBacking:` / `convertRectToBacking:` (on `NSScreen`) | 10.7 (`NSScreen` backing conversion methods) | 10.7 | Replace with identity — these calls become straight pass-through since scale is always 1.0; can `#define` a passthrough macro/inline that returns the rect unchanged | REPLACE (identity function) |
| `video/out/cocoa/video_view.m:41` `[self convertRectToBacking:[self frame]]` (`NSView`) | 10.7 | 10.7 | Replace with `[self frame]` directly (identity, since scale is always 1x) | REPLACE (identity) |
| `video/out/cocoa/events_view.m:155` `[self convertPointToBacking:point]` (`NSView`) | 10.7 | 10.7 | Replace with the point unchanged (identity) | REPLACE (identity) |
| `video/out/cocoa/window.m:206` `windowDidChangeBackingProperties:` (delegate method + implicit `NSWindowDidChangeBackingPropertiesNotification`) | 10.7.4 (notification added in Lion GM 10.7, more precisely with the display-scale-change support) | 10.7 | Delete this delegate method — the notification is never posted pre-10.7; screen profile changes are instead handled via `windowDidChangeScreenProfile:` (still valid, see below) which already exists and is 10.5-safe (`NSWindowDidChangeScreenProfileNotification` dates to 10.0) | DELETE |
| `VOCTRL_GET_HIDPI_SCALE` (`vo_OLD.h:119`) and `VO_EVENT_DPI` (`vo_OLD.h:47`) | n/a (mpv-internal enum, not an AppKit API) | — | Not itself a system API; the *implementation* backing it (backingScaleFactor) is what needs fixing above. Keep the enum, always return 1.0 from the VOCTRL handler | DELETE (of the underlying value path only) |

---

## 3. NSApplication presentationOptions vs Carbon `SetSystemUIMode` — REPLACE

`NSApplicationPresentationOptions` / `-[NSApplication setPresentationOptions:]` was introduced
in 10.6 (Snow Leopard) as the Cocoa replacement for the Carbon `SetSystemUIMode()` call. This
means it is **usable on 10.6 but not on 10.5**.

| File:Line | API | Introduced | Suggested fix | Severity |
|---|---|---|---|---|
| `video/out/cocoa/window.m:127-128` `[NSApp setPresentationOptions:NSApplicationPresentationAutoHideMenuBar\|NSApplicationPresentationAutoHideDock]` | 10.6 | 10.6 (unavailable on 10.5) | On 10.5, replace with Carbon `SetSystemUIMode(kUIModeAllHidden, kUIOptionAutoShowMenuBar)` (`#import <Carbon/Carbon.h>`, already linked-in transitively for keycodes per `macosx_events.m` comment — but note mpv's own comment there says "Carbon is NOT linked to mpv's binary", so linking Carbon.framework must be added to the 10.5 build target). Guard with `#if MAC_OS_X_VERSION_MIN_REQUIRED < 1060` / runtime `NSAppKitVersionNumber` check to pick the Carbon path on 10.5 and the Cocoa path on 10.6+ | GUARD (10.5 needs REPLACE with `SetSystemUIMode`; 10.6 can keep as-is) |
| `video/out/cocoa/window.m:146` `[NSApp setPresentationOptions:NSApplicationPresentationDefault]` | 10.6 | 10.6 | Same as above — pair with `SetSystemUIMode(kUIModeNormal, 0)` on 10.5 | GUARD |

---

## 4. OpenGL pixel-format / profile attributes — GUARD (compile-time), core profile REDESIGN-N/A

`kCGLPFAOpenGLProfile` and the `CGLOpenGLProfile` enum (`kCGLOGLPVersion_3_2_Core`,
`kCGLOGLPVersion_Legacy`) were introduced in **10.7** alongside OpenGL 3.2 core profile support.
They do not exist in the 10.5 or 10.6 `OpenGL.framework` headers at all — this is a hard compile
failure on both target OSes, not just a runtime issue.

| File:Line | API | Introduced | Suggested fix | Severity |
|---|---|---|---|---|
| `video/out/opengl/context_cocoa.c:56` `CGLOpenGLProfile` type + `test_gl_version()` | 10.7 | 10.7 | On 10.5/10.6 there is exactly one legacy/compatibility profile — delete profile selection entirely, don't add `kCGLPFAOpenGLProfile` to the attribute array at all | DELETE |
| `video/out/opengl/context_cocoa.c:63` `kCGLPFAOpenGLProfile` attribute | 10.7 | 10.7 | Remove from `attrs[]`; the array's fallback-on-`kCGLBadAttribute` loop logic can stay for the *other* attributes (`kCGLPFASupportsAutomaticGraphicsSwitching` — see next row) | DELETE |
| `video/out/opengl/context_cocoa.c:64` `(CGLPixelFormatAttribute) ver` cast of `kCGLOGLPVersion_3_2_Core`/`_Legacy` | 10.7 | 10.7 | Remove — no profile value to pass at all pre-10.7 | DELETE |
| `video/out/opengl/context_cocoa.c:68` `kCGLPFASupportsAutomaticGraphicsSwitching` | 10.6 (dual-GPU MacBook Pros started 10.6.4-ish) | 10.6 (GUARD for 10.5), fine on 10.6 | `#if` guard: on 10.5 there was no automatic graphics switching hardware in the field (all 10.5-capable Macs either have a single GPU or manual switching), so drop this attribute unconditionally pre-10.6, keep for 10.6+ | GUARD |
| `video/out/opengl/context_cocoa.c:107-110` `gl_versions[]` array (`{kCGLOGLPVersion_3_2_Core, kCGLOGLPVersion_Legacy}`) and the loop over it | 10.7 | 10.7 | Delete the array/loop; call `test_gl_version()`-equivalent exactly once with no profile attribute, since compatibility/legacy is implicitly the only profile pre-10.7 | DELETE |
| `video/out/opengl/context_cocoa.c:79,86` `CGLChoosePixelFormat` | 10.0 | — | Fine as-is, pre-10.5 API | (no change) |
| `video/out/opengl/context_cocoa.c:128` `kCGLCPSurfaceOpacity` | 10.0 | — | Fine | (no change) |
| `video/out/opengl/context_cocoa.c:37` `kCGLCPSwapInterval` | 10.0 | — | Fine | (no change) |

Additionally: `gl_context_OLD.h`/`gpu_context_OLD.h` (`ra_gl_ctx_*`) contain no direct AppKit/CGL
calls — they're pure C plumbing and are 10.5-safe as written. No findings there.

---

## 5. Event API renames (`NSEventType*`, `NSEventModifierFlag*`, `NSEventMask*`)

These are a naming-only concern: the underlying event model (`NSEvent`, `NSKeyDown` etc.) is
ancient (10.0), but Apple renamed the enum constants in the 10.12 (Sierra) SDK headers
(`NSKeyDownMask` → `NSEventMaskKeyDown`, `NSShiftKeyMask` → `NSEventModifierFlagShift`, etc).
**The new names do not exist in the 10.5/10.6 SDKs at all** — this is a hard compile error on
old SDKs, even though the underlying runtime behavior has existed since 10.0.

| File:Line | API | Introduced (name) | Suggested fix | Severity |
|---|---|---|---|---|
| `osdep/macosx_events.m:63-64` `NSEventModifierFlagOption` (used to define `NSLeftAlternateKeyMask`/`NSRightAlternateKeyMask`) | name: 10.12; underlying value: 10.0 (`NSAlternateKeyMask`) | REPLACE name with `NSAlternateKeyMask`, or add compatibility `#define`s in `macosx_compat.h` (currently empty — this is exactly what that file should be used for) mapping new names to old ones when building against the 10.5/10.6 SDK | REPLACE |
| `osdep/macosx_events.m:317,319,324,390` `NSEventModifierFlagShift/Control/Command` | 10.12 (name); old names `NSShiftKeyMask`, `NSControlKeyMask`, `NSCommandKeyMask` since 10.0 | REPLACE with old names or compat `#define`s | REPLACE |
| `osdep/macosx_events.m:329,332-333,379` `NSEventType`, `NSEventTypeKeyDown`, `NSEventTypeKeyUp` | 10.12 (name); old names `NSKeyDown`/`NSKeyUp` (type `NSEventType` itself existed earlier but the `NSEventType*` prefixed constant names are 10.12) | REPLACE with `NSKeyDown`/`NSKeyUp` | REPLACE |
| `osdep/macosx_menubar.m:102-103` `NSEventModifierFlagCommand`, `NSEventModifierFlagOption` | 10.12 (name) | REPLACE with `NSCommandKeyMask`/`NSAlternateKeyMask` | REPLACE |
| `video/out/cocoa_common.m:359` `NSEventMaskLeftMouseUp` | 10.12 (name); old name `NSLeftMouseUpMask` since 10.0 | REPLACE with `NSLeftMouseUpMask` | REPLACE |
| `video/out/cocoa/events_view.m:267,269` `NSEventModifierFlagShift` | 10.12 (name) | REPLACE | REPLACE |
| `video/out/cocoa/mpvadapter.h` (n/a directly, but adapter passes `[event modifierFlags]` int around — fine, `modifierFlags` itself is 10.0) | — | — | — | (no change) |

**Recommendation:** the cleanest fix is a block of compatibility `#define`s in the currently-
empty `osdep/macosx_compat.h`, conditioned on SDK version, e.g.:
```c
#if MAC_OS_X_VERSION_MAX_ALLOWED < 1070 // pre-Lion SDK doesn't have the new names
  #define NSEventModifierFlagShift   NSShiftKeyMask
  #define NSEventModifierFlagControl NSControlKeyMask
  #define NSEventModifierFlagOption  NSAlternateKeyMask
  #define NSEventModifierFlagCommand NSCommandKeyMask
  #define NSEventTypeKeyDown NSKeyDown
  #define NSEventTypeKeyUp   NSKeyUp
  #define NSEventMaskLeftMouseUp NSLeftMouseUpMask
#endif
```
This turns ~12 call sites into a single-file REPLACE instead of touching every call site.

### NSEventSubtype / precise scroll deltas
- `video/out/cocoa/events_view.m:263` `[event hasPreciseScrollingDeltas]` — **10.7** (trackpad
  precise-scroll API introduced with Lion Magic Mouse/trackpad scroll-phase support). On
  10.5/10.6 no device reports precise deltas (Mighty Mouse scroll wheel only). REPLACE: guard
  with `respondsToSelector:` or just `#if`-compile it out and always take the `else` branch
  (`scrollingDeltaX/Y` / `deltaX/Y` — see next line). Severity: **GUARD** (runtime
  `respondsToSelector:` check, since the selector doesn't exist pre-10.7 the message send itself
  needs a compile-time guard too since it's not declared in the SDK — so really **REPLACE**:
  always take the non-precise path.)
- `video/out/cocoa/events_view.m:268,270` `[event scrollingDeltaX]`/`scrollingDeltaY]` — **10.6**
  (`NSEvent` gained `scrollingDeltaX/Y` in Snow Leopard alongside the new trackpad scroll
  events; not present in 10.5). On 10.5 only `deltaX`/`deltaY` (10.0) exist. REPLACE: guard
  `scrollingDeltaX/Y` for 10.6+ only, fall back to `deltaX`/`deltaY` on 10.5. Severity: GUARD.
- `video/out/cocoa/events_view.m:245-253` `preciseScroll:` method itself using `[event deltaY]`/
  `[event deltaX]` — those two (bare `deltaX`/`deltaY`) are 10.0-safe, no issue.

---

## 6. Occlusion state / NSAppearance / unified titlebar / other 10.9+ items

None of `NSWindowOcclusionState`, `NSAppearance`, `effectiveAppearance`,
`NSVisualEffectView`, or unified-titlebar APIs are actually **used** in this codebase's `.m`
files — they only appear as *option name strings* (`macos-title-bar-appearance`,
`macos-title-bar-material` in `osdep/macosx_application.m:45-58`), which are `OPT_CHOICE`
string/enum option table entries with no corresponding `.m` implementation code in this file
set (the Swift `macOS_swift.h`/`macOS_swift` implementation is out of scope — not present in
this directory). No live `NSAppearance`/`NSVisualEffectView` calls exist here to flag.

| File:Line | API | Introduced | Suggested fix | Severity |
|---|---|---|---|---|
| `osdep/macosx_application.m:45-58` `macos-title-bar-appearance`/`macos-title-bar-material` option tables (string choices only, e.g. `"vibrantDark"`, `"hudWindow"`) | option values reference 10.9-10.10 concepts (`NSVisualEffectView` = 10.10, `NSAppearance` = 10.9) but no code here *applies* them | If the Swift `cocoa_cb` backend (not in this file set) is excluded from the 10.5/10.6 target (it must be — Swift itself requires 10.9+ minimum deployment and doesn't exist as a language until 2014), these options become dead/no-op on old builds | DELETE (the options can stay as inert parsed-but-unused config, or be `#if HAVE_MACOS_COCOA_CB`-gated out entirely since that whole feature is Swift/cocoa_cb-only — confirm `HAVE_MACOS_COCOA_CB` is unset for the 10.5/10.6 build, which the `#if HAVE_MACOS_COCOA_CB` guards in `macosx_application.m:36-38,188-191` and `macosx_events.m:41-43,285` already partially handle) |
| `osdep/macosx_menubar.m:36` `[NSWindow setAllowsAutomaticWindowTabbing:NO]` | **10.12** (Sierra window tabbing) | 10.12 | DELETE outright (`#if`-gate) — the selector does not exist pre-10.12 and window tabbing is a non-concept on 10.5/10.6 | DELETE |

No occlusion-state (`NSWindowOcclusionState`, 10.9) usage found anywhere in the tree — clean.

---

## 7. Notification Center / media keys / sleep assertions / power APIs

| File:Line | API | Introduced | Suggested fix | Severity |
|---|---|---|---|---|
| `video/out/cocoa_common.m:23` `#import <IOKit/pwr_mgt/IOPMLib.h>` | 10.0 (IOPM assertions API itself) | — | Fine | (no change) |
| `video/out/cocoa_common.m:156-160` `IOPMAssertionCreateWithName`, `kIOPMAssertionTypePreventUserIdleDisplaySleep`, `kIOPMAssertionLevelOn` | **10.6** (Snow Leopard) — `IOPMAssertionCreateWithName` (the friendly named-reason variant) is 10.6+; 10.5 only has the older `IOPMAssertionCreate(CFStringRef assertionType, IOPMAssertionLevel level, IOPMAssertionID *id)` (two-arg, no name string) | 10.6 (needs REPLACE for 10.5) | On 10.5: use `IOPMAssertionCreate(kIOPMAssertionTypeNoDisplaySleep, kIOPMAssertionLevelOn, &s->power_mgmt_assertion)` — note the assertion type constant itself also differs: `kIOPMAssertionTypePreventUserIdleDisplaySleep` (10.6-named type string) vs. the 10.5-era `kIOPMAssertionTypeNoDisplaySleep`. Guard both the function call and the type constant by SDK/OS version | GUARD (10.5 REPLACE, 10.6 fine) |
| `video/out/cocoa_common.m:149-150` `IOPMAssertionRelease`, `kIOPMNullAssertionID` | 10.5 (`IOPMAssertionRelease` and `kIOPMNullAssertionID` both present since 10.5 — confirmed in the 10.5 `IOPMLib.h`) | — | Fine, no change needed | (no change) |
| `video/out/cocoa_common.m:83` `IOPMAssertionID power_mgmt_assertion` field | 10.5 | — | Fine | (no change) |
| `osdep/macosx_events.m` `RemoteCommandCenter`/media keys (`#if HAVE_MACOS_MEDIA_PLAYER`) | `MPRemoteCommandCenter` (MediaPlayer.framework) is **10.12.2+ / iOS-derived**, definitely not in scope for 10.5/10.6 | 10.12.2 | Confirm `HAVE_MACOS_MEDIA_PLAYER` is unset for old-OS builds — it's already `#if`-gated (`macosx_events.m:300`), so this is correctly guarded already, just make sure the build config disables it | DELETE (already conditionally compiled out; just verify the flag is off) |
| Ambient light sensor (`IOServiceGetMatchingService("AppleLMUController")`, `video/out/cocoa_common.m:223-262`) | IOKit APIs used (`IOServiceGetMatchingService`, `IONotificationPortCreate`, `IOServiceAddInterestNotification`, `IOServiceOpen`) are all 10.0-era IOKit, but `IONotificationPortSetDispatchQueue` (line 236-237) is **10.6+** (requires libdispatch) | 10.6 (GUARD for 10.5) | On 10.5 (no GHz dispatch queues), replace `IONotificationPortSetDispatchQueue` with `IONotificationPortGetRunLoopSource` + `CFRunLoopAddSource` (the pre-GCD idiom, valid since 10.0) | GUARD/REPLACE (10.5 needs the run-loop-source variant; 10.6 can keep dispatch queue) |
| `mach_task_self()`, `mach/mach.h` (`video/out/cocoa_common.m:26,244`) | 10.0 | — | Fine | (no change) |

---

## 8. `dispatch_*` (Grand Central Dispatch) — GUARD, 10.5 has no libdispatch at all

**libdispatch/GCD was introduced in 10.6 (Snow Leopard).** 10.5 has *no dispatch queues, no
blocks runtime shipped by the OS* (Blocks-the-language-feature is a compiler/clang feature that
*can* target 10.5 with a backport runtime, but `dispatch_get_main_queue()` and friends are
**not present in 10.5 libSystem** — this is a link-time/runtime failure, not just a header
issue). Every `dispatch_*` call in this tree must be flagged.

| File:Line | API | Introduced | Suggested fix | Severity |
|---|---|---|---|---|
| `osdep/macosx_events.m:171-172` `dispatch_once_t`, `dispatch_once()` (singleton init) | 10.6 | 10.6 | On 10.5: replace with a `pthread_once_t`/`pthread_once()`-based singleton, or simple non-thread-safe lazy-init guarded by the existing `NSCondition`/`@synchronized` pattern already used elsewhere in this class | GUARD (10.5 REPLACE with pthread_once, 10.6+ keep dispatch_once) |
| `osdep/macosx_events.m:250` `dispatch_sync(dispatch_get_main_queue(), ^{...})` | 10.6 | 10.6 | On 10.5: replace with `[self performSelectorOnMainThread:...withObject:...waitUntilDone:YES]` (10.0-safe) plus manual argument marshaling since blocks capture state that `performSelector` can't — likely needs a small helper object/struct instead of a block | REPLACE (10.5), keep dispatch (10.6+) |
| `osdep/macosx_events.m:263` `dispatch_async(dispatch_get_main_queue(), ^{...})` | 10.6 | 10.6 | Same as above but `waitUntilDone:NO` | REPLACE (10.5) |
| `osdep/macosx_menubar.m:756` `dispatch_after(dispatch_time(...), dispatch_get_main_queue(), ^{...})` | 10.6 (`dispatch_after`/`dispatch_time`) | 10.6 | On 10.5: replace with `[NSObject performSelector:withObject:afterDelay:]` (10.0-safe, `NSRunLoop` timer-based) | REPLACE (10.5) |
| `osdep/macosx_application.m:105,307` `dispatch_async(dispatch_get_main_queue(), ^{...})` (`terminate_cocoa_application`, `atexit_b` block) | 10.6 | 10.6 | Same as above — `performSelectorOnMainThread:withObject:waitUntilDone:NO` | REPLACE (10.5) |
| `video/out/cocoa_common.m:124` `run_on_main_thread()` → `dispatch_sync(dispatch_get_main_queue(), block)` | 10.6 | 10.6 | This is the **highest-traffic** dispatch call site — nearly every VO operation routes through `run_on_main_thread()`. On 10.5, reimplement using `performSelectorOnMainThread:withObject:waitUntilDone:YES` with a small invocation-wrapper object holding the block's captured state (or convert to a C function-pointer + context-struct calling convention instead of blocks, avoiding Blocks runtime dependency entirely) | REPLACE (10.5) — **high-impact, touches ~15 call sites indirectly** |
| `video/out/cocoa_common.m:236-237` `IONotificationPortSetDispatchQueue(..., dispatch_get_main_queue())` | 10.6 | 10.6 | See §7 — use `IONotificationPortGetRunLoopSource` on 10.5 | REPLACE (10.5) |
| `osdep/macosx_application.m:341,364` uses of `mp_thread_create`/`mp_thread_join`, `atexit_b` — `atexit_b` itself (block-based atexit) is a **glibc/BSD extension**, not present as such on Darwin; check this is actually mpv's own `osdep/threads.h` wrapper, not a system call | n/a — need to verify | — | Not a flagged Apple API if it's mpv's internal wrapper; verify `atexit_b` resolves to mpv's own helper and not a system function assuming blocks | UNSURE (flagging for verification, likely internal) |

**Blocks language feature itself:** every block literal (`^{ ... }`, `^(NSString *p, ...){ ... }`)
found in `osdep/macosx_events.m`, `osdep/macosx_menubar.m`, `osdep/macosx_application.m`, and
`video/out/cocoa_common.m` requires either (a) the Blocks runtime, which needs backporting to
10.5 (Apple's own clang can target 10.5 with `-fblocks` plus linking a `libBlocksRuntime.a`
shim — this is a known, documented workaround used by e.g. MacPorts/legacy toolchains), or
(b) rewriting all block literals as ordinary C functions + context pointers. Given the sheer
number of blocks used purely as "run this on the main thread" glue, **recommend keeping Blocks
syntax but linking a static Blocks runtime shim for 10.5**, and only replacing the
`dispatch_*` *queue* calls (which have no 10.5 OS-level implementation at all, shim or not)
with `performSelectorOnMainThread:`/pthread equivalents. This is called out as REDESIGN-adjacent
because it's an architecture-level decision each block site above inherits from.

`[files enumerateObjectsUsingBlock:^(...){...}]` (`osdep/macosx_events.m:394`) — 10.6 API
(`NSArray -enumerateObjectsUsingBlock:`). REPLACE with a plain `for (id p in files)` loop
(10.0-safe fast enumeration) — trivial, no reason to keep the block form. Severity: REPLACE.

---

## 9. CVDisplayLink usage — clean (10.4+), verify callback signature only

`CVDisplayLink` itself is CoreVideo, introduced **10.4** — fully safe for 10.5/10.6. The
callback signature used here (`CVDisplayLinkCallback` — `CVReturn (*)(CVDisplayLinkRef,
const CVTimeStamp*, const CVTimeStamp*, CVOptionFlags, CVOptionFlags*, void*)`) matches the
signature that has been stable since its 10.4 introduction; no changes needed.

| File:Line | API | Introduced | Verdict |
|---|---|---|---|
| `video/out/cocoa_common.m:50-52,343-345,511-513` `CVDisplayLinkCreateWithCGDisplay`, `CVDisplayLinkSetOutputCallback`, callback signature | 10.4 | Clean — no change |
| `video/out/cocoa_common.m:327-334,351` `CVDisplayLinkStart/Stop/IsRunning/Release` | 10.4 | Clean — no change |
| `video/out/cocoa_common.m:489-490` `CVDisplayLinkGetActualOutputVideoRefreshPeriod`, `CVDisplayLinkGetNominalOutputVideoRefreshPeriod` | 10.4 | Clean — no change |

---

## 10. Miscellaneous additional findings (not in the prompt's explicit checklist)

| File:Line | API | Introduced | Suggested fix | Severity |
|---|---|---|---|---|
| `video/out/cocoa/window.m:97,103,112,124,141,285,379-380,408,442` and `video/out/cocoa_common.m:872,966,998,1000` etc. `[self.adapter isInFullScreenMode]` / `NSWindowCollectionBehaviorFullScreenPrimary`-adjacent flag logic | n/a (mpv's own bool state) | — | Not itself a system API, but its correctness is entirely contingent on the fullscreen redesign in §1 | (covered by §1) |
| `video/out/cocoa/events_view.m:96-98` `NSWindow +frameRectForContentRect:styleMask:` (class method) | 10.0 | — | Fine, old API | (no change) |
| `video/out/cocoa/events_view.m:103` `[self.window convertRectFromScreen:vF]` | **10.7** (`NSWindow` screen↔base rect conversion methods `convertRectFromScreen:`/`convertRectToScreen:` were added in Lion; pre-10.7 the idiom was `convertBaseToScreen:`/`convertScreenToBase:`, point-only, no rect variant) | 10.7 | REPLACE: manually compute via `NSPoint origin = [self.window convertBaseToScreen:vF.origin]; NSRect converted = NSMakeRect(origin.x, origin.y, vF.size.width, vF.size.height);` (both `convertBaseToScreen:`/`convertScreenToBase:` are 10.0-safe and remained available, though deprecated, through 10.14) | REPLACE |
| `osdep/macosx_menubar.m:725,737` `NSModalResponseOK` | **10.9** (Mavericks) — old name was `NSOKButton` (10.0, `NSPanel`/`NSOpenPanel` return codes) | 10.9 | REPLACE with `NSOKButton` (works unchanged all the way back to 10.0; also still valid on modern SDKs as a deprecated alias) | REPLACE |
| `video/out/cocoa/window.m:206,226` `windowDidChangeBackingProperties:` (see §2), `windowDidChangeScreenProfile:` | Backing-properties: 10.7 (DELETE per §2). ScreenProfile: `NSWindowDidChangeScreenProfileNotification` is 10.0-safe — no issue there | — | Keep `windowDidChangeScreenProfile:`, delete `windowDidChangeBackingProperties:` | (screen-profile: no change; backing-properties: DELETE, already listed in §2) |
| `osdep/macosx_menubar.m:789` `[workspace activateFileViewerSelectingURLs:urlArray]` | **10.6** (`NSWorkspace -activateFileViewerSelectingURLs:`; pre-10.6 idiom was `-selectFile:inFileViewerRootedAtPath:`) | 10.6 (GUARD for 10.5) | On 10.5: use `[workspace selectFile:[url path] inFileViewerRootedAtPath:@""]` | GUARD (10.5 REPLACE, 10.6 fine) |
| `osdep/macosx_menubar.m:36` — see §6, `setAllowsAutomaticWindowTabbing:` | 10.12 | 10.12 | DELETE | DELETE |
| `video/out/cocoa_common.m:20` `#include <stdatomic.h>` | C11 / not an AppKit version issue per se, but old Apple GCC-based 10.5 toolchains (GCC 4.0/4.2) predate C11 `stdatomic.h` entirely; only clang with a recent-enough libc++/compiler-rt provides it. **Toolchain concern, not an OS-version concern** — flagging because building for PPC/10.5 commonly means using an older or cross-compiling toolchain that may lack `stdatomic.h` | UNSURE — toolchain-dependent, not strictly an AppKit API-floor issue | If cross-compiling with a modern clang targeting `-mmacosx-version-min=10.5`, `stdatomic.h` availability depends on the *compiler*, not the OS, so likely fine with a modern clang; verify with the actual PPC cross-toolchain in use. If using vintage GCC for PPC, replace with `OSAtomic*` (`libkern/OSAtomic.h`, 10.0-safe) or manual `pthread_mutex` guarding | GUARD/UNSURE |
| `video/out/cocoa_common.m:37` `#include "osdep/timer.h"`, `mp_thread`/`mp_mutex`/`mp_cond` (osdep threading wrappers used throughout `cocoa_common.m`) | mpv-internal — likely pthread-based | — | Not an Apple API; presumed 10.5-safe pending verification of `osdep/threads.h` implementation (out of scope directory) | UNSURE (out of audited scope) |

---

## Summary table by severity

| Severity | Count (distinct findings/rows above) |
|---|---|
| DELETE | 11 |
| GUARD | 9 |
| REPLACE | 16 |
| REDESIGN | 9 |
| UNSURE | 3 |

(Counts are per audit-table row, which sometimes groups several call sites of the same API
under one finding; see §-by-§ detail above for exact `file:line` occurrences — roughly 90+
individual call sites are covered across the ~50 distinct API findings.)

## Biggest-risk items, ranked

1. **Lion fullscreen protocol** (§1) — `toggleFullScreen:` override, `NSWindowStyleMaskFullScreen`,
   the full `NSWindowDelegate` fullscreen callback family, `NSWindowCollectionBehaviorFullScreenPrimary`.
   No 10.5/10.6 equivalent primitive exists; must fall back permanently to the existing
   "manual/non-native fullscreen" branch (borderless window + `setFrame:`) and delete the
   native path for old-OS builds. This is the only REDESIGN category with no small patch fix.
2. **`dispatch_*`/GCD throughout `run_on_main_thread()`** (§8) — 10.6+ only, no 10.5
   implementation exists in libSystem at all; `run_on_main_thread()` is mpv's central
   main-thread-marshaling primitive and is called from nearly every VO control path, so this
   is high blast-radius even though each individual fix (swap for
   `performSelectorOnMainThread:`) is mechanically simple.
3. **`SetSystemUIMode` vs `NSApplicationPresentationOptions`** (§3) — 10.6-only Cocoa API;
   10.5 needs the Carbon call, and Carbon.framework linkage must be added back to the build
   (a comment in the source explicitly notes Carbon is currently *not* linked).
4. **OpenGL core-profile attribute (`kCGLPFAOpenGLProfile`)** (§4) — hard compile failure on
   both 10.5 and 10.6 SDKs (constant doesn't exist pre-10.7); straightforward DELETE since
   legacy/compatibility profile is the only option anyway on this hardware.
5. **Backing-store/HiDPI conversions** (§2) — all 10.7+, all safe to delete/replace with
   identity functions since the hardware can never have a scale factor other than 1.0.
