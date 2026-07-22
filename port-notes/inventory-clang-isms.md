# Inventory: Clang/Apple-GCC-only ObjC constructs blocking FSF GCC compilation

Scope: all `.m`/`.h` files under `old_cocoa/` (osdep/, video/out/, video/out/cocoa/,
video/out/opengl/ — note: no files exist under video/out/opengl/ in this tree).

Legend: **MECHANICAL** = pattern-replaceable without a design decision (e.g. block
literal -> static C function + context struct, following an established idiom).
**JUDGMENT** = requires deciding lifetime/ownership/threading/data-modeling (e.g. a
block that captures locals and runs async/later, or literal-based data tables that
need restructuring).

Files confirmed clean of every category below (no ObjC-post-GCC syntax at all —
pure C, or plain declarations only):
- `gl_context_OLD.h`
- `gpu_context_OLD.h`
- `vo_OLD.h`
- `osdep/macosx_compat.h` (0 bytes / empty)
- `osdep/macosx_events.h`
- `osdep/macosx_menubar.h`
- `video/out/cocoa_common.h`
- `video/out/cocoa/mpvadapter.h` — clean except one `@property` (listed below)
- No files found under `video/out/opengl/` in this scratchpad tree.

---

## osdep/macosx_application.h

### 5. @property
| Line | Snippet | Synthesize in .m? |
|---|---|---|
| 37 | `@property(nonatomic, retain) MenuBar *menuBar;` | yes — `macosx_application.m:112` |
| 38 | `@property(nonatomic, assign) size_t openCount;` | yes — `macosx_application.m:113` |
| 39 | `@property(nonatomic, retain) CocoaCB *cocoaCB;` | yes — `macosx_application.m:114` |

All three properties in this file have explicit `@synthesize`. **MECHANICAL** (already conformant — no fix needed, just confirms auto-synthesis isn't relied upon here).

No blocks, no dispatch, no literals, no subscripting, no ARC attributes, no other post-GCC syntax in this header.

---

## osdep/macosx_application.m

### 1 & 2. Block literals / libdispatch (block-based)
| Line | Snippet | Category |
|---|---|---|
| 105-108 | `dispatch_async(dispatch_get_main_queue(), ^{`<br>`    [NSApp hide:NSApp];`<br>`    [NSApp terminate:NSApp];`<br>`});` in `terminate_cocoa_application()` | libdispatch, block-based. **MECHANICAL** — no captured mutable state beyond global `NSApp`; straightforward to convert to `dispatch_async_f`/a plain function pointer, or to a synchronous direct call since it only touches globals. |
| 303-310 | `atexit_b(^{`<br>`    // ...`<br>`    dispatch_async(dispatch_get_main_queue(), ^{`<br>`        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];`<br>`    });`<br>`});` in `init_cocoa_application()` | Block literal passed to `atexit_b` (a block-taking variant of `atexit()`, not itself declared in this tree — presumably libc/libSystem or an mpv shim), **nested** inside which is a second `dispatch_async` block literal. **JUDGMENT** — `atexit_b` itself is a block-consuming API; there's no non-block `atexit()`-compatible way to pass a closure capturing nothing here (it captures nothing, actually, so it *could* mechanically become a plain top-level static function passed to `atexit()`), but the inner nested `dispatch_async` block adds a second layer that also needs conversion. Because it's nested block-in-block and depends on an external (possibly Apple-only) `atexit_b` symbol, flag as JUDGMENT to confirm whether `atexit_b` is available/necessary under FSF-GCC toolchain at all, or whether plain `atexit()` suffices (the block captures no locals, so plain `atexit()` + static fn should work). |

### 2. libdispatch usage summary (this file)
- `dispatch_async(dispatch_get_main_queue(), ^{...})` — line 105, block-based.
- `dispatch_async(dispatch_get_main_queue(), ^{...})` — line 307, block-based (nested inside atexit_b block).
- No `dispatch_sync`, `dispatch_once`, `dispatch_queue_t` variables, or function-pointer-based dispatch (`dispatch_async_f`, etc.) in this file.

### 3. ObjC container/boxed literals
| Line | Snippet | Category |
|---|---|---|
| 168 | `tBar.defaultItemIdentifiers = @[play, previousItem, nextItem, seekBar];` (inside `#if HAVE_MACOS_TOUCHBAR`) | Array literal. **MECHANICAL** — replace with `[NSArray arrayWithObjects:...,nil]`. Note: entire block is gated by `HAVE_MACOS_TOUCHBAR`, likely unused on the powerpc-darwin/NeXT-runtime target, but still must compile-clean if the macro can be on. |
| 169-171 | `tBar.customizationAllowedItemIdentifiers = @[play, seekBar, previousItem,`<br>`    nextItem, previousChapter, nextChapter, cycleAudio, cycleSubtitle,`<br>`    currentPosition, timeLeft];` (inside `#if HAVE_MACOS_TOUCHBAR`) | Array literal. **MECHANICAL** — same as above. |
| 241 | `[_eventsResponder handleFilesArray:@[url]];` | Single-element array literal. **MECHANICAL** — `[NSArray arrayWithObject:url]`. |

### 4. ObjC object subscripting
None found in this file (all `argv[...]`, `m_option[...]`, `macosx_icon[]` are plain C arrays).

### 5. @property / @synthesize
See macosx_application.h table above; matches confirmed at lines 112-114 (`@synthesize menuBar = _menu_bar;`, `@synthesize openCount = _open_count;`, `@synthesize cocoaCB = _cocoa_cb;`).

Also note a **class extension** with an instance ivar (no properties) at line 91-96:
```
@interface Application ()
{
    EventsResponder *_eventsResponder;
}
@end
```
Not a property — plain ivar declared in a class-extension block. This is ObjC-2.0-legal, GCC-compatible (extension syntax is fine; only *auto-synthesis* of properties without ivars is the risk, and this isn't a property at all).

### 6. Other post-GCC syntax
- `@autoreleasepool { ... }` — **two occurrences**:
  - line 276: inside `playback_thread()`.
  - line 346: inside `cocoa_main()`.
  `@autoreleasepool` is Clang/modern-runtime sugar; under MRC + NeXT runtime this must become explicit `NSAutoreleasePool` alloc/init/drain, as is already done elsewhere in this same file (see `cocoa_run_runloop()` at lines 266-271, which correctly uses the MRC idiom). **MECHANICAL** — same substitution pattern used in `cocoa_run_runloop`.
- No `instancetype`, `NS_ENUM`/`NS_OPTIONS`, `@import`, generics, nullability, or `__attribute__((objc_...))` found.

### 7. ARC-flavored constructs
None. File uses `[super dealloc]` (line 145) and manual retain/release patterns consistent with MRC. No `strong`/`weak`/`__bridge` attributes found.

---

## osdep/macosx_application_objc.h

### 5. @property
| Line | Snippet | Synthesize? |
|---|---|---|
| 37 | `@property(nonatomic, retain) MenuBar *menuBar;` | yes, `macosx_application.m:112` |
| 38 | `@property(nonatomic, assign) size_t openCount;` | yes, `macosx_application.m:113` |
| 39 | `@property(nonatomic, retain) CocoaCB *cocoaCB;` | yes, `macosx_application.m:114` |

(Same file content/duplication note: this appears to be the actual header pulled in by `#import "osdep/macosx_application_objc.h"`; `macosx_application.h` above is the C-only public header. Both were read and both contain the identical `@property` block — this is not a bug in the audit, the repo simply has this content in both places per the provided file paths.) No other post-GCC constructs.

---

## osdep/macosx_events.h

Clean. Pure C declarations (function prototypes only, no ObjC).

---

## osdep/macosx_events.m

### 1 & 2. Block literals / libdispatch (block-based)
| Line | Snippet | Category |
|---|---|---|
| 171-176 | `static dispatch_once_t onceToken;`<br>`dispatch_once(&onceToken, ^{`<br>`    responder = [EventsResponder new];`<br>`});` in `+sharedInstance` | `dispatch_once` + block. **MECHANICAL** — classic singleton-init pattern; convertible to a plain static-initializer / `pthread_once`-style guard, or simple non-thread-contested lazy init if threading guarantees allow (needs a decision on whether to keep dispatch_once via a static helper or replace with a mutex-guarded flag — bordering **JUDGMENT** only because of thread-safety semantics, but the block itself captures nothing async-relevant, so mechanically convertible). |
| 250-253 | `dispatch_sync(dispatch_get_main_queue(), ^{`<br>`    _ctx = ctx;`<br>`    [NSApp setMpvHandle:ctx];`<br>`});` in `-setMpvHandle:` | `dispatch_sync` + block capturing `self` (`_ctx` ivar) and parameter `ctx`. **MECHANICAL** — synchronous, so lifetime of captured variables is trivially bounded by the call; convert to a small static function + struct-of-args passed to `dispatch_sync_f`, or to direct main-thread dispatch machinery. |
| 263-270 | `dispatch_async(dispatch_get_main_queue(), ^{`<br>`    while (_ctx) {`<br>`        mpv_event *event = mpv_wait_event(_ctx, 0);`<br>`        if (event->event_id == MPV_EVENT_NONE)`<br>`            break;`<br>`        [self processEvent:event];`<br>`    }`<br>`});` in `-readEvents` | `dispatch_async` + block capturing `self` (implicitly, via `_ctx` ivar access and `[self processEvent:]`), runs **asynchronously** later on the main queue. **JUDGMENT** — self-lifetime across an async block boundary under MRC needs an explicit retain/release (or the call site must guarantee `self` outlives the queued block), which is a design decision, not a mechanical rewrite. |
| 394-400 | `[files enumerateObjectsUsingBlock:^(NSString *p, NSUInteger i, BOOL *_){`<br>`    if ([p hasPrefix:@"file:///.file/id="])`<br>`        p = [[NSURL URLWithString:p] path];`<br>`    char *filename = (char *)[p UTF8String];`<br>`    size_t bytes   = [p lengthOfBytesUsingEncoding:NSUTF8StringEncoding];`<br>`    files_utf8[i]  = talloc_memdup(files_utf8, filename, bytes + 1);`<br>`}];` in `-handleFilesArray:` | `NSArray enumerateObjectsUsingBlock:` — block-taking Cocoa API, captures local C array `files_utf8` (mutated inside block) and `talloc` context. **JUDGMENT** — `enumerateObjectsUsingBlock:` has no non-block equivalent in the Cocoa API itself; must be rewritten as a `for (NSString *p in files)` fast-enumeration loop with an explicit index counter (fast enumeration IS GCC/ObjC-2.0-legal per the prompt's allowed list), which changes control flow (no early-stop via `*stop`, but this block never sets `*stop` anyway so it's a safe transform) — flagged JUDGMENT because it changes the iteration idiom, even though the actual replacement (fast enumeration) is straightforward. |

### 2. libdispatch usage summary (this file)
- `dispatch_once_t` variable + `dispatch_once(...)` — line 171-172, block-based.
- `dispatch_sync(dispatch_get_main_queue(), ...)` — line 250, block-based.
- `dispatch_async(dispatch_get_main_queue(), ...)` — line 263, block-based.
- No function-pointer-based (`_f` suffix) dispatch calls anywhere in this file.

### 3. ObjC container/boxed literals
| Line | Snippet | Category |
|---|---|---|
| 331-334 | `NSDictionary *map = @{`<br>`    @(NSEventTypeKeyDown) : @(MP_KEY_STATE_DOWN),`<br>`    @(NSEventTypeKeyUp)   : @(MP_KEY_STATE_UP),`<br>`};` in `-mapTypeModifiers:` | Dictionary literal **and** two pairs of boxed-expression literals (`@(NSEventTypeKeyDown)`, `@(MP_KEY_STATE_DOWN)`, etc.) — 4 boxed exprs total on lines 332-333. **MECHANICAL** — small fixed table; convert to `[NSDictionary dictionaryWithObjectsAndKeys:...]` with `[NSNumber numberWith...:]` wrapping, or (simpler/better) just replace this whole dict-based lookup with a plain C `switch`/table, since it's an integer-to-integer map masquerading as an NSDictionary. |

### 4. ObjC object subscripting
| Line | Snippet | Receiver | Category |
|---|---|---|---|
| 335 | `return [map[@(type)] intValue];` | `map` is `NSDictionary *` — this is `-objectForKeyedSubscript:` (also contains a nested boxed expression `@(type)` as the key). **MECHANICAL** once `map` itself is rewritten (see above); the subscript syntax converts to `[map objectForKey:@(type)]` or, if `map` is eliminated in favor of a switch, this whole line disappears. |

### 5. @property / @synthesize
| Line | Snippet | Synthesize? |
|---|---|---|
| `macosx_events_objc.h:43` | `@property(nonatomic, retain) RemoteCommandCenter *remoteCommandCenter;` | yes — `macosx_events.m:166` `@synthesize remoteCommandCenter = _remoteCommandCenter;` |

All properties have explicit synthesize. **MECHANICAL** (already conformant).

Also note: class extension `@interface EventsResponder () { ... }` at line 45-51 declares plain ivars (`_inputContext`, `_ctx`, `_is_application`, `_input_lock`) — not properties, no synthesis concern.

### 6. Other post-GCC syntax
None beyond what's covered by the container-literal and dispatch/block items above. No `instancetype`, `NS_ENUM`, `@autoreleasepool`, `@import`, generics, nullability, `__attribute__((objc_...))`.

### 7. ARC-flavored constructs
None — MRC-consistent (`retain` property attributes, manual locking via `NSCondition`, no `strong`/`weak`/`__bridge`).

---

## osdep/macosx_events_objc.h

### 5. @property
| Line | Snippet | Synthesize? |
|---|---|---|
| 43 | `@property(nonatomic, retain) RemoteCommandCenter *remoteCommandCenter;` | yes, `macosx_events.m:166` |

No other post-GCC constructs. Clean otherwise.

---

## osdep/macosx_menubar.h

Clean. Pure C enum + header guard, no ObjC.

---

## osdep/macosx_menubar.m

This file is the single largest source of Apple-literal usage in the whole tree — the entire static menu tree (`menuTree` ivar) is built from nested `@[...]` array literals and `@{...}` dictionary literals (many wrapped in `[NSMutableDictionary dictionaryWithDictionary:@{...}]`).

### 1 & 2. Block literals / libdispatch
| Line | Snippet | Category |
|---|---|---|
| 756-758 | `dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{`<br>`    [input becomeFirstResponder];`<br>`});` in `-openURL` | `dispatch_after` + block capturing local `NSTextField *input`. **JUDGMENT** — capture of a local across a deferred (0.1s delayed) async callback; needs explicit retain of `input` for the lifetime of the deferred call under MRC (input is already retained by `alert`'s accessory view, so likely safe, but that's a lifetime argument a human needs to make, not a pure mechanical substitution). `dispatch_after` itself has no non-block form; would need `dispatch_after` replaced with `NSTimer` (scheduled on the main run loop, calling a selector) or a raw GCD `dispatch_after` is still block-only in libdispatch — actually there IS `dispatch_after_f`? No — no `_f` variant of `dispatch_after` exists in libdispatch. Must redesign as `performSelector:withObject:afterDelay:` or `NSTimer`, which is itself a design change → JUDGMENT. |

Libdispatch summary (this file): only the one `dispatch_after`/`dispatch_time`/`dispatch_get_main_queue()` combo above; block-based; no function-pointer variant used or available for `dispatch_after`.

### 3. ObjC container/boxed literals (exhaustive line list)

**Array literals (`@[`)** — 12 occurrences:
lines 38, 41, 131, 167, 203, 238, 316, 365, 414, 535, 550 (all as `"menu": @[` sub-arrays or the top-level `menuTree = @[` at line 38), plus line 688 `NSArray *configPaths = @[`.

**Dictionary literals (`@{`)** — many dozens of occurrences (both bare `@{ @"name": @"separator" }` entries and `@{ ... }` wrapped by `[NSMutableDictionary dictionaryWithDictionary:@{ ... }]`). Representative sample (full set spans lines 39-613):
- Bare separator dicts: lines 48, 85, 90, 112, 150, 178, 226, 260, 296, 331, 339, 380, 388, 443, 465, 501, 516, 565, 594 — e.g. line 48: `@{ @"name": @"separator" },`
- Top-level category dicts: lines 39 (`Apple`), 129 (`File`), 165 (`Edit`), 201 (`View`), 236 (`Video`), 314 (`Audio`), 363 (`Subtitle`), 412 (`Playback`), 533 (`Window`), 548 (`Help`).
- `[NSMutableDictionary dictionaryWithDictionary:@{...}]`-wrapped menu-item dicts: lines 42, 49, 67, 86, 91, 97, 106, 113, 120, 132, 138, 144, 151, 156, 168, 173, 179, 184, 189, 194, 204, 211, 218, 227, 239, 246, 253, 261, 268, 275, 282, 289, 297, 302, 307, 317, 324, 332, 340, 347, 354, 366, 373, 381, 389, 396, 403, 415, 422, 429, 436, 444, 451, 458, 466, 473, 480, 487, 494, 502, 509, 517, 524, 536, 541, 551, 558, 566, 573, 580, 587, 595, 602 (73 occurrences).

All of these are **MECHANICAL** in the sense that they're a uniform, repeated pattern (`@{ @"k":@"v", ... }` → `[NSDictionary dictionaryWithObjectsAndKeys:...]` or a helper macro/function; `@[...]` → `[NSArray arrayWithObjects:...,nil]`), but the sheer *volume* (this static menu table is ~600 lines) makes a full manual rewrite a substantial, error-prone task best done via a scripted/regex-assisted transform plus careful review — noting this because "mechanical" here does not mean "trivial effort," just "no design decision required." Recommend a one-time helper (e.g. a variadic C-string-keyed dict builder or a redesigned plain-C table + a build routine) rather than 73 manual literal-to-message-send conversions.

### 3 (boxed numeric literals used as dict values, distinct from container literals)
| Lines | Snippet | Category |
|---|---|---|
| 101-103 | `@"modifiers" : [NSNumber numberWithUnsignedInteger: NSEventModifierFlagCommand | NSEventModifierFlagOption],` | NOT a literal — already uses classic `+numberWithUnsignedInteger:` factory method, GCC-safe. Included here only to note it is *not* an occurrence (contrast with boxed `@(...)` forms found elsewhere in this file — see below). |
| 300, 305, 310, 539, 544 | `"cmdSpecial" : [NSNumber numberWithInt:MPM_H_SIZE]` (and `MPM_N_SIZE`, `MPM_D_SIZE`, `MPM_MINIMIZE`, `MPM_ZOOM`) | Same — already GCC-safe factory-method style, not `@(...)` boxed literal. No action needed for these five lines; flagged only to confirm they were checked and are clean. |

(No `@(...)` boxed-expression literals actually appear in this file — grep for `@(` returned zero hits in `macosx_menubar.m`. All numeric wrapping in this file already uses the pre-literal `+numberWith...:` idiom, which is GCC/MRC compatible.)

### 4. ObjC object subscripting (exhaustive)
All receivers below are `id`-typed loop variables (`mMenu`, `subMenu`) or `NSMutableDictionary *` (`mItemDict`) — genuine ObjC dictionary subscripting via `-objectForKeyedSubscript:` / `-setObject:forKeyedSubscript:`, **not** C arrays:

| Line | Snippet |
|---|---|
| 628 | `NSMenu *menu = [[NSMenu alloc] initWithTitle:mMenu[@"name"]];` |
| 629 | `NSMenuItem *mItem = [mainMenu addItemWithTitle:mMenu[@"name"]` |
| 634 | `for(id subMenu in mMenu[@"menu"]) {` |
| 635 | `NSString *name = subMenu[@"name"];` |
| 636 | `NSString *action = subMenu[@"action"];` |
| 653 | `keyEquivalent:subMenu[@"key"]];` |
| 654 | `[iItem setTarget:subMenu[@"target"]];` |
| 657 | `NSNumber *m = subMenu[@"modifiers"];` |
| 662 | `if ([subMenu[@"name"] isEqual:@"Services"]) {` |
| 693 | `NSString *fileP = [path stringByAppendingString:mItemDict[@"file"]];` |
| 698-699 | `[self alertWithTitle:mItemDict[@"alertTitle1"] andText:mItemDict[@"alertText1"]];` |
| 703-704 | `[self alertWithTitle:mItemDict[@"alertTitle2"] andText:mItemDict[@"alertText2"]];` |
| 709-710 | `[self alertWithTitle:mItemDict[@"alertTitle3"] andText:mItemDict[@"alertText3"]];` |
| 715 | `NSString *cmd = [self getDictFromMenuItem:menuItem][@"cmd"];` (subscripting the *return value* of a method call) |
| 716 | *(uses `cmd` from above, not itself a new subscript)* |
| 740 | `[pl UTF8String]];` *(not subscripting; noted during review, no action)* |
| 768 | `NSString *cmd = [self getDictFromMenuItem:menuItem][@"cmd"];` |
| 774 | `NSString *url = [self getDictFromMenuItem:menuItem][@"url"];` |
| 783 | `NSString *file = [mItemDict[@"file"] stringByExpandingTildeInPath];` |
| 793-794 | `[self alertWithTitle:mItemDict[@"alertTitle"] andText:mItemDict[@"alertText"]];` |
| 810 | `for(id subMenu in mMenu[@"menu"]) {` |
| 811 | `if([subMenu[@"menuItem"] isEqual:menuItem])` |
| 822 | `for(id subMenu in mMenu[@"menu"]) {` |
| 823 | `if([subMenu[@"cmdSpecial"] isEqual:[NSNumber numberWithInt:key]]) {` |
| 824 | `[subMenu[@"menuItem"] setAction:action];` |

Also **write-subscripting** (`-setObject:forKeyedSubscript:`) is used implicitly? — checked: line 655 `[subMenu setObject:iItem forKey:@"menuItem"];` uses the classic `-setObject:forKey:` message send, NOT subscript-assignment syntax (`subMenu[@"menuItem"] = iItem;` does not appear). So all subscripting in this file is **read-only** (`-objectForKeyedSubscript:`), never `[]=` assignment. **MECHANICAL** — every instance converts to `[recv objectForKey:@"key"]`; large in count (24 occurrences) but uniform and safe to batch-convert.

### 5. @property / @synthesize
None declared in this file (`MenuBar` class has one plain ivar `NSArray *menuTree;` at line 26, no `@property`).

### 6. Other post-GCC syntax
None beyond the literals/subscripting/dispatch already covered.

### 7. ARC-flavored constructs
None — file uses `alloc`/no matching explicit `release` visible in the excerpt for locally-created menu objects, but that's a possible MRC leak issue (pre-existing bug, not an ARC-flavored syntax marker) — out of scope for this syntax inventory per instructions (inventory only, no fixes/behavior judgments beyond required MECHANICAL/JUDGMENT tagging for the listed categories).

---

## video/out/cocoa/events_view.h

### 5. @property
| Line | Snippet | Synthesize? |
|---|---|---|
| 22 | `@property(nonatomic, retain) MpvCocoaAdapter *adapter;` | yes — `events_view.m:33` |

Clean otherwise.

---

## video/out/cocoa/events_view.m

### 1. Block literals
None (`enumerateObjectsUsingBlock:` is NOT used here — that was in `macosx_events.m`). No `dispatch_*`, no blocks.

### 3. ObjC container/boxed literals
| Line | Snippet | Category |
|---|---|---|
| 41-42 | `[self registerForDraggedTypes:@[NSFilenamesPboardType,`<br>`                                NSURLPboardType]];` | Array literal, 2 elements. **MECHANICAL**. |
| 324 | `[self.adapter handleFilesArray:@[[url absoluteString]]];` | Single-element array literal (nested message send as the element). **MECHANICAL**. |

### 4. ObjC object subscripting
None found.

### 5. @property / @synthesize
| Line | Snippet | Synthesize? |
|---|---|---|
| `events_view.m:25` (class extension, in the .m) | `@property(nonatomic, assign) BOOL hasMouseDown;` | yes — line 35 `@synthesize hasMouseDown = _mouse_down;` |
| `events_view.m:26` (class extension, in the .m) | `@property(nonatomic, retain) NSTrackingArea *tracker;` | yes — line 34 `@synthesize tracker = _tracker;` |
| `events_view.h:22` | `@property(nonatomic, retain) MpvCocoaAdapter *adapter;` | yes — line 33 `@synthesize adapter = _adapter;` |

All three properties (2 declared in a private class-extension inside the .m at lines 25-26, plus 1 in the public header) have explicit `@synthesize` at lines 33-35. **MECHANICAL** (already conformant).

### 6/7. Other
No `instancetype`, no ARC markers, no other post-GCC constructs. `isFlipped`, fast enumeration not used here (uses classic loops/array messaging) — nothing else to flag.

---

## video/out/cocoa/mpvadapter.h

### 5. @property
| Line | Snippet | Synthesize? |
|---|---|---|
| 40 | `@property(nonatomic, assign) struct vo *vout;` | yes — `cocoa_common.m:941` `@synthesize vout = _video_output;` |

Clean otherwise (pure `@interface` declaration, no other post-GCC syntax).

---

## video/out/cocoa/video_view.h

### 5. @property
| Line | Snippet | Synthesize? |
|---|---|---|
| 22 | `@property(nonatomic, retain) MpvCocoaAdapter *adapter;` | yes — `video_view.m:22` |

Clean otherwise.

---

## video/out/cocoa/video_view.m

No blocks, no dispatch, no literals, no subscripting, no other post-GCC syntax.

### 5. @property / @synthesize
| Line | Snippet | Synthesize? |
|---|---|---|
| (declared in `video_view.h:22`) | `@property(nonatomic, retain) MpvCocoaAdapter *adapter;` | yes — line 22: `@synthesize adapter = _adapter;` |

**MECHANICAL** (already conformant). Nothing else to flag in this file.

---

## video/out/cocoa/window.h

### 5. @property
| Line | Snippet | Synthesize? |
|---|---|---|
| 27 | `@property(nonatomic, retain) MpvCocoaAdapter *adapter;` | yes — `window.m:43` |

Also defines protocol `MpvWindowUpdate` (lines 21-24) — plain ObjC 2.0 `@protocol`, GCC-compatible, no `@optional`/`@required` markers needed to flag (none used). Clean otherwise.

---

## video/out/cocoa/window.m

### 1. Block literals
None. No `dispatch_*` calls in this file.

### 3/4. Literals / subscripting
None found.

### 5. @property / @synthesize
Declared in a class extension at the top of the .m (lines 27-35):
| Line | Snippet | Synthesize? |
|---|---|---|
| 28 | `@property(nonatomic, retain) NSScreen *targetScreen;` | yes — line 44 |
| 29 | `@property(nonatomic, retain) NSScreen *previousScreen;` | yes — line 45 |
| 30 | `@property(nonatomic, retain) NSScreen *currentScreen;` | yes — line 46 |
| 31 | `@property(nonatomic, retain) NSScreen *unfScreen;` | yes — line 47 |
| (`window.h:27`) | `@property(nonatomic, retain) MpvCocoaAdapter *adapter;` | yes — line 43 |

All 5 properties visible to this implementation (4 private + 1 public `adapter`) have explicit `@synthesize` at lines 43-47:
```
@synthesize adapter = _adapter;
@synthesize targetScreen = _target_screen;
@synthesize previousScreen = _previous_screen;
@synthesize currentScreen = _current_screen;
@synthesize unfScreen = _unf_screen;
```
**MECHANICAL** (already conformant).

Also note: `@implementation MpvVideoWindow { NSSize _queued_video_size; NSRect _unfs_content_frame; int _is_animating; }` at line 37 — plain ivar block inside `@implementation`, ObjC-2.0-legal syntax (not a property), no synthesis concern.

### 6/7. Other
No `instancetype`, no ARC markers, no other post-GCC constructs. Note: extensive use of dot-syntax (`self.targetScreen = ...`, `[self.adapter isInFullScreenMode]`, etc.) throughout — dot-syntax is explicitly listed by the prompt as GCC-supported (ObjC 2.0), so not flagged as an issue, just noted for completeness since it's pervasive in this file.

---

## video/out/cocoa_common.h

Clean. Pure C declarations only (uses `CGLContextObj` from the OpenGL framework, but no ObjC syntax).

---

## video/out/cocoa_common.m

This file mixes plain-C VO-driver code with an `@implementation MpvCocoaAdapter` section at the bottom (lines 940-1101).

### 1 & 2. Block literals / libdispatch

**Block-type declaration (not a literal, a type in a function signature):**
| Line | Snippet | Category |
|---|---|---|
| 122 | `static void run_on_main_thread(struct vo *vo, void(^block)(void))` | Block-typed parameter declaration for a small internal helper. **JUDGMENT** — this is the central abstraction every other block literal in the file (and in `macosx_application.m`/`macosx_events.m` indirectly, since `cocoa_register_menu_item_action` etc. don't use it, but every `run_on_main_thread(vo, ^{...})` call site in *this* file does) routes through. Redesigning this helper (e.g. to take a `void (*fn)(void *ctx)` + `void *ctx` function-pointer pair instead of a block) is the single highest-leverage change in the whole tree, but it requires deciding the new calling convention for ~9 call sites below — a design decision, not a mechanical find/replace. |

**Block literals passed to `run_on_main_thread` (all `dispatch_sync`-semantics, since `run_on_main_thread` wraps `dispatch_sync` internally at line 124):**
| Line | Snippet | Captures | Category |
|---|---|---|---|
| 225-253 | `run_on_main_thread(vo, ^{`<br>`    struct vo_cocoa_state *s = vo->cocoa;`<br>`    ... IOServiceGetMatchingService/IONotificationPortCreate/IOServiceAddInterestNotification/IOServiceOpen ...`<br>`});` in `cocoa_init_light_sensor()` | `vo` (function param) | Large block body (~28 lines) with multiple early `return`s from inside the block. **JUDGMENT** — early-return-from-block semantics differ from early-return-from-function; converting to a plain static function requires restructuring control flow (each `return;` inside the block must become `return;` from the new function, which is actually fine here since `run_on_main_thread` is synchronous and the block is the entire function body — still flagged JUDGMENT due to size/complexity and multiple exit points, not simple substitution). |
| 396-399 | `run_on_main_thread(vo, ^{`<br>`    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];`<br>`    set_application_icon(NSApp);`<br>`});` in `vo_cocoa_init()` | none (only touches `NSApp` global) | **MECHANICAL** — no captures beyond globals; trivial to hoist into a static function. |
| 441-448 | `run_on_main_thread(vo, ^{`<br>`    // if using --wid + libmpv there's no window to release`<br>`    if (s->window) {`<br>`        vo_cocoa_update_cursor_visibility(vo, true);`<br>`        [s->window setDelegate:nil];`<br>`        [s->window close];`<br>`    }`<br>`});` in `vo_cocoa_uninit()` | `s` (outer local, computed just above at line 427: `struct vo_cocoa_state *s = vo->cocoa;`), `vo` | **MECHANICAL** (synchronous call, captures are simple pointers, no lifetime extension past the call). |
| 450-475 | `run_on_main_thread(vo, ^{`<br>`    enable_power_management(s);`<br>`    vo_cocoa_uninit_displaylink(s);`<br>`    ... [s->nsgl_ctx release]; CGLReleaseContext(s->cgl_ctx); [s->video removeFromSuperview]; [s->view removeFromSuperview]; [s->view release]; ... talloc_free(s);`<br>`});` in `vo_cocoa_uninit()` | `s`, `vo` | **MECHANICAL** by the same reasoning (synchronous, captures simple pointers) — flagged only because the block body is long (~25 lines) and ends by freeing `s` itself, so care is needed that the converted function still runs synchronously before `vo_cocoa_uninit` returns; not a lifetime-across-async issue since `dispatch_sync` blocks until completion. |
| 695-698 | `run_on_main_thread(vo, ^{`<br>`    s->cgl_ctx = CGLRetainContext(ctx);`<br>`    s->nsgl_ctx = [[NSOpenGLContext alloc] initWithCGLContextObj:s->cgl_ctx];`<br>`});` in `vo_cocoa_set_opengl_ctx()` | `s` (local computed at line 694), `ctx` (function param) | **MECHANICAL**. |
| 706-754 | `run_on_main_thread(vo, ^{`<br>`    NSRect r = [s->current_screen frame];`<br>`    ... (48-line body: geometry calc, create_ui(), window title, CGL param query, [s->nsgl_ctx update] ...`<br>`});` in `vo_cocoa_config_window()` | `s`, `vo`, `opts` (locals) | **JUDGMENT** — largest block in the file (~48 lines), calls `create_ui()` which itself allocates windows/views/adapters; the sheer complexity and multiple local variables declared *inside* the block (`geo`, `screenrc`, `width`, `height`, `reset_size`, `frame`, `o`) make this worth human review even though it's synchronous and mechanically convertible in principle. |
| 933-936 | `run_on_main_thread(vo, ^{`<br>`    r = vo_cocoa_control_on_main_thread(vo, request, arg);`<br>`});` in `vo_cocoa_control()` | `r` (a `__block int` declared at line 931 — see below), `vo`, `request`, `arg` | **JUDGMENT** — captures a `__block`-qualified local that is *written inside* the block and read after `run_on_main_thread` returns. Because the call is synchronous (`dispatch_sync`), this is safe as written, but the `__block` qualifier itself (see item 6/`__block` below) has no FSF-GCC / non-blocks equivalent — must become an explicit pointer/out-parameter to the converted function, which is a signature-level design change. |

**Standalone block literal — event monitor handler (not via `run_on_main_thread`):**
| Line | Snippet | Category |
|---|---|---|
| 358-363 | `s->event_monitor_mouseup = [NSEvent`<br>`    addLocalMonitorForEventsMatchingMask: NSEventMaskLeftMouseUp`<br>`                                 handler:^NSEvent*(NSEvent* event) {`<br>`        s->window_is_dragged = false;`<br>`        return event;`<br>`    }];` in `cocoa_add_event_monitor()` | `NSEvent addLocalMonitorForEventsMatchingMask:handler:` — a block-taking Cocoa API with **no non-block equivalent** in AppKit. Captures `s` (outer local). **JUDGMENT** — this needs a real design decision: either drop local-event-monitor-based drag-tracking entirely and find another mechanism (e.g. tracking via `mouseUp:` overrides already present in `events_view.m`/`window.m`), or find/implement an alternative API. Not a mechanical substitution since AppKit provides no `_f`/selector-based form of this particular registration API. |

### 2. libdispatch usage summary (this file)
- `dispatch_sync(dispatch_get_main_queue(), block)` — line 124, inside `run_on_main_thread()`. This is the one dispatch call that takes a **variable of block type** (`block`, the function parameter) rather than an inline block literal — same underlying issue (needs the block type gone), but worth noting it's function-pointer-*adjacent* in that `run_on_main_thread` itself could become a thin wrapper if redesigned around `dispatch_sync_f` (which DOES exist as a function-pointer-based libdispatch API: `void dispatch_sync_f(dispatch_queue_t queue, void *context, dispatch_function_t work)`). **This is the key insight for a design fix** (JUDGMENT to adopt), not present as a "already function-pointer-based" call in the current code — flagging it as an opportunity.
- `dispatch_get_main_queue()` — used at lines 124, 237 (as an argument to `IONotificationPortSetDispatchQueue`, not a dispatch call itself but consumes a `dispatch_queue_t`).
- No `dispatch_once`, no `dispatch_async`/`dispatch_after` in this file (those are in the other files above).

### 3. ObjC container/boxed literals
None found in this file (grep for `@[`, `@{`, `@(` returned zero hits here).

### 4. ObjC object subscripting
None — all bracketed expressions in this file (`values[outputs]`, `values[0]`, `values[1]`, `sz[0]`, `sz[1]`) are plain C array indexing on C types (`uint64_t values[]`, `int *sz`), not ObjC subscripting.

### 5. @property / @synthesize
| Location | Snippet | Synthesize? |
|---|---|---|
| `mpvadapter.h:40` | `@property(nonatomic, assign) struct vo *vout;` | yes — `cocoa_common.m:941` `@synthesize vout = _video_output;` |

**MECHANICAL** (already conformant).

### 6. Other post-GCC syntax
| Line | Snippet | Category |
|---|---|---|
| 931 | `__block int r = vo_cocoa_control_async(vo, events, request, arg);` | `__block` storage qualifier — Apple-Clang blocks-runtime feature, has no meaning/support without the blocks extension. **JUDGMENT** — must be redesigned as an explicit out-parameter or pointer once the enclosing block (line 933) is converted; tightly coupled to the `run_on_main_thread`/block-signature redesign discussed above. |

No `instancetype`, `NS_ENUM`/`NS_OPTIONS`, `@autoreleasepool`, `@import`, generics, or nullability annotations found in this file.

### 7. ARC-flavored constructs
None — file is consistently MRC (explicit `[icon release]`, `[pool release]`, `[s->nsgl_ctx release]`, `[s->video release]`, `[s->view release]`, `[adapter release]`, manual `NSAutoreleasePool` usage at lines 169/181 in `set_application_icon()`). No `strong`/`weak`/`__bridge` attributes anywhere.

---

# Cross-file summary tables

## @property inventory — ALL properties found, with synthesize status

| File (declared) | Line | Property | @synthesize location | Missing? |
|---|---|---|---|---|
| osdep/macosx_application_objc.h | 37 | `menuBar` | macosx_application.m:112 | No |
| osdep/macosx_application_objc.h | 38 | `openCount` | macosx_application.m:113 | No |
| osdep/macosx_application_objc.h | 39 | `cocoaCB` | macosx_application.m:114 | No |
| osdep/macosx_events_objc.h | 43 | `remoteCommandCenter` | macosx_events.m:166 | No |
| video/out/cocoa/mpvadapter.h | 40 | `vout` | cocoa_common.m:941 | No |
| video/out/cocoa/events_view.h | 22 | `adapter` | events_view.m:33 | No |
| video/out/cocoa/events_view.m (class ext.) | 25 | `hasMouseDown` | events_view.m:35 | No |
| video/out/cocoa/events_view.m (class ext.) | 26 | `tracker` | events_view.m:34 | No |
| video/out/cocoa/video_view.h | 22 | `adapter` | video_view.m:22 | No |
| video/out/cocoa/window.h | 27 | `adapter` | window.m:43 | No |
| video/out/cocoa/window.m (class ext.) | 28 | `targetScreen` | window.m:44 | No |
| video/out/cocoa/window.m (class ext.) | 29 | `previousScreen` | window.m:45 | No |
| video/out/cocoa/window.m (class ext.) | 30 | `currentScreen` | window.m:46 | No |
| video/out/cocoa/window.m (class ext.) | 31 | `unfScreen` | window.m:47 | No |

**Result: every single `@property` in this codebase (14 total) already has an explicit, matching `@synthesize`. Zero properties rely on auto-synthesis.** This is good news for the FSF-GCC port — no missing-synthesize fixes are needed anywhere; this whole category is a non-issue for this codebase.

## Block / libdispatch inventory — all sites, by file

| File | Line(s) | API | Block-based or fn-ptr? |
|---|---|---|---|
| osdep/macosx_application.m | 105 | `dispatch_async` | block |
| osdep/macosx_application.m | 303 | `atexit_b` | block |
| osdep/macosx_application.m | 307 | `dispatch_async` (nested in atexit_b block) | block |
| osdep/macosx_events.m | 171-172 | `dispatch_once` | block |
| osdep/macosx_events.m | 250 | `dispatch_sync` | block |
| osdep/macosx_events.m | 263 | `dispatch_async` | block |
| osdep/macosx_events.m | 394 | `-enumerateObjectsUsingBlock:` (NSArray) | block |
| osdep/macosx_menubar.m | 756 | `dispatch_after` | block |
| video/out/cocoa_common.m | 122 | block-typed param `void(^block)(void)` | block (type decl) |
| video/out/cocoa_common.m | 124 | `dispatch_sync` (wraps the above param) | block |
| video/out/cocoa_common.m | 225, 396, 441, 450, 695, 706, 933 | `run_on_main_thread(vo, ^{...})` (7 call sites) | block |
| video/out/cocoa_common.m | 358-363 | `-addLocalMonitorForEventsMatchingMask:handler:` (NSEvent) | block |

**No function-pointer-based libdispatch calls (`dispatch_async_f`, `dispatch_sync_f`, etc.) are used anywhere in this codebase today** — every single dispatch call is block-based. `dispatch_sync_f` exists in libdispatch and is the natural mechanical target for the `run_on_main_thread` helper if redesigned.

## Object-literal / subscripting inventory — counts by file

| File | `@[` array lit | `@{` dict lit | `@(...)` boxed | subscript `x[k]` (ObjC) |
|---|---|---|---|---|
| osdep/macosx_application.m | 3 (lines 168,169,241) | 0 | 0 | 0 |
| osdep/macosx_events.m | 0 | 1 (line 331) | 3 (332×2, 333... actually 4: 332,332,333,333) | 1 (line 335, `map[@(type)]`) |
| osdep/macosx_menubar.m | 12 | ~85 (bare + wrapped) | 0 | 24 |
| video/out/cocoa/events_view.m | 2 (lines 41,324) | 0 | 0 | 0 |
| **Totals** | **17** | **~86** | **4** | **25** |

(macosx_events.m boxed count detail: line 332 has 2 `@(...)` exprs, line 333 has 2 `@(...)` exprs = 4 total on those two lines.)

---

# Priority notes for the port (informational, not a fix plan)

1. **`macosx_menubar.m`** is by far the largest single conversion job: ~100 combined literal/subscript occurrences building one static data table. A scripted/templated conversion is strongly advised over manual editing.
2. **`video/out/cocoa_common.m`**'s `run_on_main_thread()` + `__block` pairing (lines 122-125, 931-936) is the highest-leverage *design* decision in the tree: redesigning it around `dispatch_sync_f` (function-pointer-based, already part of libdispatch, no blocks needed) would mechanically resolve 7 of the file's 8 block call sites in one stroke, leaving only the `NSEvent addLocalMonitorForEventsMatchingMask:handler:` call (line 358) as a genuinely blocks-only Cocoa API requiring a different design.
3. **`NSEvent addLocalMonitorForEventsMatchingMask:handler:`** (cocoa_common.m:358) and **`NSArray enumerateObjectsUsingBlock:`** (macosx_events.m:394) are the two Cocoa-framework APIs in this tree that are *inherently* block-only with no selector/function-pointer alternative offered by AppKit/Foundation — these need actual redesign (drop the API / use a different one), not mere syntax substitution.
4. **`dispatch_after`** (macosx_menubar.m:756) has no `_f` function-pointer variant in libdispatch at all — the only escape is `NSTimer` or `performSelector:withObject:afterDelay:`, a genuine design change.
5. Every `@property`/`@synthesize` pair is already explicit — this category requires no work.
6. No ARC, no `instancetype`, no `NS_ENUM`/`NS_OPTIONS`, no `@autoreleasepool` outside `macosx_application.m` (2 uses, mechanically convertible per the existing MRC pattern already present in the same file), no `@import`, no generics, no nullability annotations, and no `__attribute__((objc_...))` anywhere in the audited tree.
