/*
 * Cocoa OpenGL Backend
 *
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

// NOTE: no <stdatomic.h> here — FSF GCC cannot compile C11 _Atomic inside an
// ObjC translation unit ("sorry, unimplemented: '_Atomic' in Objective-C"),
// and this file does not actually use any atomics.

#import <Cocoa/Cocoa.h>
#include "osdep/mac/compat_legacy.h"
#include <AvailabilityMacros.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/IOKitLib.h>
#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#include <mach/mach.h>

#if MAC_OS_X_VERSION_MIN_REQUIRED < 1060
// TransformProcessType(): the 10.5 activation-policy fallback
#include <ApplicationServices/ApplicationServices.h>
#endif

#import "cocoa_common.h"
#import "video/out/cocoa/window.h"
#import "video/out/cocoa/events_view.h"
#import "video/out/cocoa/video_view.h"
#import "video/out/cocoa/mpvadapter.h"

#include "osdep/threads.h"
#include "osdep/mac/events_objc.h"
#include "osdep/mac/mainthread.h"

#include "osdep/timer.h"
#include "osdep/mac/app_objc.h"

#include "options/options.h"
#include "options/m_config.h"
#include "video/out/vo.h"
#include "win_state.h"

#include "input/input.h"
#include "mpv_talloc.h"

#include "common/msg.h"

static CVReturn displayLinkCallback(CVDisplayLinkRef displayLink, const CVTimeStamp* now,
                                    const CVTimeStamp* outputTime, CVOptionFlags flagsIn,
                                    CVOptionFlags* flagsOut, void* displayLinkContext);
static int vo_cocoa_fullscreen(struct vo *vo);
static void cocoa_add_screen_reconfiguration_observer(struct vo *vo);
static void cocoa_rm_screen_reconfiguration_observer(struct vo *vo);

struct vo_cocoa_state {
    // --- The following members can be accessed only by the main thread (i.e.
    //     where Cocoa runs), or if the main thread is fully blocked.

    NSWindow *window;
    NSView *view;
    MpvVideoView *video;
    MpvCocoaAdapter *adapter;

    CGLContextObj cgl_ctx;
    NSOpenGLContext *nsgl_ctx;

    NSScreen *current_screen;
    CGDirectDisplayID display_id;

    NSInteger window_level;
    int fullscreen;
    NSRect unfs_window;

    bool cursor_visibility;
    bool cursor_visibility_wanted;
    bool window_is_dragged;

    bool embedded; // whether we are embedding in another GUI

    // IOPMAssertion* (the power-assertion API) is 10.5+. On 10.4 there is no
    // assertion type here; keep a compatible integer field (IOPMAssertionID is
    // a uint32_t) so the struct compiles, and make power management a no-op.
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1050
    IOPMAssertionID power_mgmt_assertion;
#else
    uint32_t power_mgmt_assertion;
#endif
    io_connect_t light_sensor;
    uint64_t last_lmuvalue;
    int last_lux;
    IONotificationPortRef light_sensor_io_port;

    struct mp_log *log;

    uint32_t old_dwidth;
    uint32_t old_dheight;

    mp_mutex anim_lock;
    mp_cond anim_wakeup;
    bool is_animating;

    CVDisplayLinkRef link;
    mp_mutex sync_lock;
    mp_cond sync_wakeup;
    uint64_t sync_counter;

    mp_mutex lock;
    mp_cond wakeup;

    // --- The following members are protected by the lock.
    //     If the VO and main threads are both blocked, locking is optional
    //     for members accessed only by VO and main thread.

    int pending_events;

    int vo_dwidth;                      // current or soon-to-be VO size
    int vo_dheight;

    bool vo_ready;                      // the VO is in a state in which it can
                                        // render frames
    int frame_w, frame_h;               // dimensions of the frame rendered

    char *window_title;
};

// HiDPI is impossible on 10.5/10.6 PPC-era hardware: the backing scale factor
// is always 1.0, so the 10.7+ backing-store conversion APIs
// (-[NSScreen convertRect{To,From}Backing:], -[NSView convertRectToBacking:],
// -backingScaleFactor) do not exist and are unnecessary. These identity
// helpers replace those call sites (see api-floor inventory §2).
#define mpv_backing_scale_factor(screen) (1.0)

static void queue_new_video_size(struct vo *vo, int w, int h)
{
    struct vo_cocoa_state *s = vo->cocoa;
    id<MpvWindowUpdate> win = (id<MpvWindowUpdate>) s->window;
    NSRect r = NSMakeRect(0, 0, w, h);
    [win queueNewVideoSize:r.size];
}

static void flag_events(struct vo *vo, int events)
{
    struct vo_cocoa_state *s = vo->cocoa;
    mp_mutex_lock(&s->lock);
    s->pending_events |= events;
    mp_mutex_unlock(&s->lock);
    if (events)
        vo_wakeup(vo);
}

static void enable_power_management(struct vo_cocoa_state *s)
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1050
    if (!s->power_mgmt_assertion) return;
    IOPMAssertionRelease(s->power_mgmt_assertion);
    s->power_mgmt_assertion = kIOPMNullAssertionID;
#else
    (void)s; // no power-assertion API on 10.4; screensaver control is a no-op
#endif
}

static void disable_power_management(struct vo_cocoa_state *s)
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1050
    if (s->power_mgmt_assertion) return;
    // kIOPMAssertionTypePreventUserIdleDisplaySleep and the friendly-named
    // IOPMAssertionCreateWithName() are 10.6+. On 10.5 use the older two-arg
    // IOPMAssertionCreate() with the legacy kIOPMAssertionTypeNoDisplaySleep
    // type string (both are present in the 10.5 IOPMLib.h). See api-floor §7.
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060
    IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep,
            kIOPMAssertionLevelOn,
            CFSTR("io.mpv.video_playing_back"),
            &s->power_mgmt_assertion);
#else
    IOPMAssertionCreate(
            kIOPMAssertionTypeNoDisplaySleep,
            kIOPMAssertionLevelOn,
            &s->power_mgmt_assertion);
#endif
#else
    (void)s; // no power-assertion API on 10.4; screensaver control is a no-op
#endif
}

static const char macosx_icon[] =
#include "TOOLS/osxbundle/icon.icns.inc"
;

static void set_application_icon(NSApplication *app)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSBundle *bundle = [NSBundle mainBundle];
    if ([bundle pathForResource:@"icon" ofType:@"icns"]) {
        [pool release];
        return;
    }

    // The C string contains a trailing null, so we strip it away
    NSData *icon_data = [NSData dataWithBytesNoCopy:(void *)macosx_icon
                                             length:sizeof(macosx_icon) - 1
                                       freeWhenDone:NO];
    NSImage *icon = [[NSImage alloc] initWithData:icon_data];
    // Only set it if the .icns actually decoded: a zero-size image triggers
    // "Cannot lock focus ... because it is size zero" spam (seen on PPC, where
    // the embedded icon may not decode). The dock icon is cosmetic anyway.
    if (icon && !NSEqualSizes([icon size], NSZeroSize))
        [app setApplicationIconImage:icon];
    [icon release];
    [pool release];
}

static int lmuvalue_to_lux(uint64_t v)
{
    // the polynomial approximation for apple lmu value -> lux was empirically
    // derived by firefox developers (Apple provides no documentation).
    // https://bugzilla.mozilla.org/show_bug.cgi?id=793728
    double power_c4 = 1/pow((double)10,27);
    double power_c3 = 1/pow((double)10,19);
    double power_c2 = 1/pow((double)10,12);
    double power_c1 = 1/pow((double)10,5);

    double term4 = -3.0 * power_c4 * pow(v,4);
    double term3 =  2.6 * power_c3 * pow(v,3);
    double term2 = -3.4 * power_c2 * pow(v,2);
    double term1 =  3.9 * power_c1 * v;

    int lux = ceil(term4 + term3 + term2 + term1 - 0.19);
    return lux > 0 ? lux : 0;
}

static void light_sensor_cb(void *ctx, io_service_t srv, natural_t mtype, void *msg)
{
    struct vo *vo = ctx;
    struct vo_cocoa_state *s = vo->cocoa;
    uint32_t outputs = 2;
    uint64_t values[outputs];

    kern_return_t kr = IOConnectCallMethod(
            s->light_sensor, 0, NULL, 0, NULL, 0, values, &outputs, nil, 0);

    if (kr == KERN_SUCCESS) {
        uint64_t mean = (values[0] + values[1]) / 2;
        if (s->last_lmuvalue != mean) {
            s->last_lmuvalue = mean;
            s->last_lux = lmuvalue_to_lux(s->last_lmuvalue);
            flag_events(vo, VO_EVENT_AMBIENT_LIGHTING_CHANGED);
        }
    }
}

static void cocoa_init_light_sensor_on_main(void *p)
{
    struct vo *vo = p;
    struct vo_cocoa_state *s = vo->cocoa;
    io_service_t srv = IOServiceGetMatchingService(
            kIOMasterPortDefault, IOServiceMatching("AppleLMUController"));
    if (srv == IO_OBJECT_NULL) {
        MP_VERBOSE(vo, "can't find an ambient light sensor\n");
        return;
    }

    // subscribe to notifications from the light sensor driver
    s->light_sensor_io_port = IONotificationPortCreate(kIOMasterPortDefault);
    // 10.5 has no libdispatch; drive the notification port from the main
    // run loop instead of a dispatch queue (both are 10.0-safe on 10.6 too,
    // and this avoids depending on libdispatch here). See api-floor §7.
    CFRunLoopSourceRef rls =
        IONotificationPortGetRunLoopSource(s->light_sensor_io_port);
    // CFRunLoopGetMain() is 10.5+; this runs on the main thread (dispatched via
    // mp_mac_run_on_main), so the current run loop is the main one on 10.4.
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1050
    CFRunLoopRef runloop = CFRunLoopGetMain();
#else
    CFRunLoopRef runloop = CFRunLoopGetCurrent();
#endif
    CFRunLoopAddSource(runloop, rls, kCFRunLoopDefaultMode);

    io_object_t n;
    IOServiceAddInterestNotification(
        s->light_sensor_io_port, srv, kIOGeneralInterest, light_sensor_cb,
        vo, &n);

    kern_return_t kr = IOServiceOpen(srv, mach_task_self(), 0,
                                     &s->light_sensor);
    IOObjectRelease(srv);
    if (kr != KERN_SUCCESS) {
        MP_WARN(vo, "can't start ambient light sensor connection\n");
        return;
    }

    light_sensor_cb(vo, 0, 0, NULL);
}

static void cocoa_init_light_sensor(struct vo *vo)
{
    mp_mac_run_on_main(cocoa_init_light_sensor_on_main, vo, true);
}

static void cocoa_uninit_light_sensor(struct vo_cocoa_state *s)
{
    if (s->light_sensor_io_port) {
        IONotificationPortDestroy(s->light_sensor_io_port);
        IOObjectRelease(s->light_sensor);
    }
}

static NSScreen *get_screen_by_id(struct vo *vo, int screen_id)
{
    struct vo_cocoa_state *s = vo->cocoa;

    NSArray *screens  = [NSScreen screens];
    int n_of_displays = [screens count];
    if (screen_id >= n_of_displays) {
        MP_INFO(s, "Screen ID %d does not exist, falling back to main "
                   "device\n", screen_id);
        return nil;
    } else if (screen_id < 0) {
        return nil;
    }
    return [screens objectAtIndex:(screen_id)];
}

static void vo_cocoa_update_screen_info(struct vo *vo)
{
    struct vo_cocoa_state *s = vo->cocoa;
    struct mp_vo_opts *opts = vo->opts;

    if (s->embedded)
        return;

    if (s->current_screen && s->window) {
        s->current_screen = [s->window screen];
    } else if (!s->current_screen) {
        s->current_screen = get_screen_by_id(vo, opts->screen_id);
        if (!s->current_screen)
            s->current_screen = [NSScreen mainScreen];
    }

    NSDictionary* sinfo = [s->current_screen deviceDescription];
    s->display_id = [[sinfo objectForKey:@"NSScreenNumber"] longValue];
}

static void vo_cocoa_anim_lock(struct vo *vo)
{
    struct vo_cocoa_state *s = vo->cocoa;
    mp_mutex_lock(&s->anim_lock);
    s->is_animating = true;
    mp_mutex_unlock(&s->anim_lock);
}

static void vo_cocoa_anim_unlock(struct vo *vo)
{
    struct vo_cocoa_state *s = vo->cocoa;
    mp_mutex_lock(&s->anim_lock);
    s->is_animating = false;
    mp_cond_signal(&s->anim_wakeup);
    mp_mutex_unlock(&s->anim_lock);
}

static void vo_cocoa_signal_swap(struct vo_cocoa_state *s)
{
    mp_mutex_lock(&s->sync_lock);
    s->sync_counter += 1;
    mp_cond_signal(&s->sync_wakeup);
    mp_mutex_unlock(&s->sync_lock);
}

static void vo_cocoa_start_displaylink(struct vo_cocoa_state *s)
{
    if (!CVDisplayLinkIsRunning(s->link))
        CVDisplayLinkStart(s->link);
}

static void vo_cocoa_stop_displaylink(struct vo_cocoa_state *s)
{
    if (CVDisplayLinkIsRunning(s->link)) {
        CVDisplayLinkStop(s->link);
        vo_cocoa_signal_swap(s);
    }
}

static void vo_cocoa_init_displaylink(struct vo *vo)
{
    struct vo_cocoa_state *s = vo->cocoa;

    CVDisplayLinkCreateWithCGDisplay(s->display_id, &s->link);
    CVDisplayLinkSetOutputCallback(s->link, &displayLinkCallback, vo);
    CVDisplayLinkStart(s->link);
}

static void vo_cocoa_uninit_displaylink(struct vo_cocoa_state *s)
{
    vo_cocoa_stop_displaylink(s);
    CVDisplayLinkRelease(s->link);
}

// The old backend cleared window_is_dragged from a global left-mouse-up event
// monitor (-[NSEvent addLocalMonitorForEventsMatchingMask:handler:], a
// blocks-only API absent from FSF GCC). Instead, MpvEventsView clears it from
// its own mouseUp: path via -[MpvCocoaAdapter clearDrag] (see events_view.m).

static void set_regular_activation_policy_on_main(void *p)
{
    // -setActivationPolicy: / NSApplicationActivationPolicyRegular are 10.6+;
    // on 10.5 promote to a foreground app via the Process Manager instead
    // (mirrors set_activation_policy() in osdep/mac/app_objc.m).
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
#else
    ProcessSerialNumber psn = {0, kCurrentProcess};
    TransformProcessType(&psn, kProcessTransformToForegroundApplication);
#endif
    set_application_icon(NSApp);
}

void vo_cocoa_init(struct vo *vo)
{
    // vo_cocoa_init() runs on mpv's VO thread, which has no autorelease pool.
    // vo_cocoa_update_screen_info() below sends Cocoa messages directly on this
    // thread (e.g. -[NSScreen deviceDescription]) that autorelease objects, so
    // wrap the body in an explicit pool to avoid "autoreleased with no pool in
    // place" leaks. (Work marshaled via mp_mac_run_on_main() runs on the main
    // thread, which already has a pool.)
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    struct vo_cocoa_state *s = talloc_zero(NULL, struct vo_cocoa_state);
    *s = (struct vo_cocoa_state){
        // kIOPMNullAssertionID (== 0) is 10.5+; the field is zero-initialized
        // anyway, so only reference the constant where it exists.
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1050
        .power_mgmt_assertion = kIOPMNullAssertionID,
#endif
        .log = mp_log_new(s, vo->log, "cocoa"),
        .embedded = vo->opts->WinID >= 0,
        .cursor_visibility = true,
        .cursor_visibility_wanted = true,
        .fullscreen = 0,
    };
    mp_mutex_init(&s->lock);
    mp_cond_init(&s->wakeup);
    mp_mutex_init(&s->sync_lock);
    mp_cond_init(&s->sync_wakeup);
    mp_mutex_init(&s->anim_lock);
    mp_cond_init(&s->anim_wakeup);
    vo->cocoa = s;
    vo_cocoa_update_screen_info(vo);
    vo_cocoa_init_displaylink(vo);
    cocoa_init_light_sensor(vo);
    cocoa_add_screen_reconfiguration_observer(vo);

    if (!s->embedded)
        mp_mac_run_on_main(set_regular_activation_policy_on_main, NULL, true);

    [pool drain];
}

static int vo_cocoa_update_cursor_visibility(struct vo *vo, bool forceVisible)
{
    struct vo_cocoa_state *s = vo->cocoa;

    if (s->embedded)
        return VO_NOTIMPL;

    if (s->view) {
        MpvEventsView *v = (MpvEventsView *) s->view;
        bool visibility = !(!s->cursor_visibility_wanted && [v canHideCursor]);

        if ((forceVisible || visibility) && !s->cursor_visibility) {
            [NSCursor unhide];
            s->cursor_visibility = YES;
        } else if (!visibility && s->cursor_visibility) {
            [NSCursor hide];
            s->cursor_visibility = NO;
        }
    }
    return VO_TRUE;
}

// close window beforehand to prevent undefined behavior when in fullscreen
// that resets the desktop to space 1
static void vo_cocoa_uninit_close_window_on_main(void *p)
{
    struct vo *vo = p;
    struct vo_cocoa_state *s = vo->cocoa;
    // if using --wid + libmpv there's no window to release
    if (s->window) {
        vo_cocoa_update_cursor_visibility(vo, true);
        [s->window setDelegate:nil];
        [s->window close];
    }
}

static void vo_cocoa_uninit_teardown_on_main(void *p)
{
    struct vo *vo = p;
    struct vo_cocoa_state *s = vo->cocoa;

    enable_power_management(s);
    vo_cocoa_uninit_displaylink(s);
    vo_cocoa_signal_swap(s);
    cocoa_uninit_light_sensor(s);
    cocoa_rm_screen_reconfiguration_observer(vo);

    [s->nsgl_ctx release];
    CGLReleaseContext(s->cgl_ctx);

    // needed to stop resize events triggered by the event's view -clear
    // causing many uses after free
    [s->video removeFromSuperview];

    [s->view removeFromSuperview];
    [s->view release];

    mp_cond_destroy(&s->anim_wakeup);
    mp_mutex_destroy(&s->anim_lock);
    mp_cond_destroy(&s->sync_wakeup);
    mp_mutex_destroy(&s->sync_lock);
    mp_cond_destroy(&s->wakeup);
    mp_mutex_destroy(&s->lock);
    talloc_free(s);
}

void vo_cocoa_uninit(struct vo *vo)
{
    struct vo_cocoa_state *s = vo->cocoa;

    mp_mutex_lock(&s->lock);
    s->vo_ready = false;
    mp_cond_signal(&s->wakeup);
    mp_mutex_unlock(&s->lock);

    mp_mutex_lock(&s->anim_lock);
    while(s->is_animating)
        mp_cond_wait(&s->anim_wakeup, &s->anim_lock);
    mp_mutex_unlock(&s->anim_lock);

    mp_mac_run_on_main(vo_cocoa_uninit_close_window_on_main, vo, true);
    mp_mac_run_on_main(vo_cocoa_uninit_teardown_on_main, vo, true);
}

static void vo_cocoa_update_displaylink(struct vo *vo)
{
    struct vo_cocoa_state *s = vo->cocoa;

    vo_cocoa_uninit_displaylink(s);
    vo_cocoa_init_displaylink(vo);
}

static double vo_cocoa_update_screen_fps(struct vo *vo)
{
    struct vo_cocoa_state *s = vo->cocoa;
    double actual_fps = CVDisplayLinkGetActualOutputVideoRefreshPeriod(s->link);
    const CVTime t = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(s->link);

    if (!(t.flags & kCVTimeIsIndefinite)) {
        double nominal_fps = (t.timeScale / (double) t.timeValue);

        if (actual_fps > 0)
            actual_fps = 1/actual_fps;

        if (fabs(actual_fps - nominal_fps) > 0.1) {
            MP_VERBOSE(vo, "Falling back to nominal display "
                           "refresh rate: %fHz\n", nominal_fps);
            return nominal_fps;
        } else {
            return actual_fps;
        }
    }

    MP_WARN(vo, "Falling back to standard display refresh rate: 60Hz\n");
    return 60.0;
}

static CVReturn displayLinkCallback(CVDisplayLinkRef displayLink, const CVTimeStamp* now,
                                    const CVTimeStamp* outputTime, CVOptionFlags flagsIn,
                                    CVOptionFlags* flagsOut, void* displayLinkContext)
{
    struct vo *vo = displayLinkContext;
    struct vo_cocoa_state *s = vo->cocoa;

    vo_cocoa_signal_swap(s);
    return kCVReturnSuccess;
}

static void vo_set_level(struct vo *vo, int ontop, int ontop_level)
{
    struct vo_cocoa_state *s = vo->cocoa;

    if (ontop) {
        switch (ontop_level) {
        case -1:
            s->window_level = NSFloatingWindowLevel;
            break;
        case -2:
            s->window_level = NSStatusWindowLevel;
            break;
        default:
            s->window_level = ontop_level;
        }
    } else {
        s->window_level = NSNormalWindowLevel;
    }

    // In manual fullscreen the window is raised above the menubar by
    // -setFullScreen:; don't clobber that level here. The desired windowed
    // level is stored and applied on fullscreen exit.
    if (!s->fullscreen)
        [s->window setLevel:s->window_level];

    // NSWindowCollectionBehavior (Spaces/exposé window-management hint) is 10.5+
    // and purely cosmetic; skip it on 10.4.
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1050
    NSWindowCollectionBehavior behavior = [s->window collectionBehavior] &
                                          ~NSWindowCollectionBehaviorTransient;
    [s->window setCollectionBehavior:behavior|NSWindowCollectionBehaviorManaged];
#endif
}

static int vo_cocoa_ontop(struct vo *vo)
{
    struct vo_cocoa_state *s = vo->cocoa;
    if (s->embedded)
        return VO_NOTIMPL;

    struct mp_vo_opts *opts = vo->opts;
    vo_set_level(vo, opts->ontop, opts->ontop_level);
    return VO_TRUE;
}

static MpvVideoWindow *create_window(NSRect rect, NSScreen *s, bool border,
                                     MpvCocoaAdapter *adapter)
{
    int window_mask = 0;
    if (border) {
        window_mask = NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|
                      NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable;
    } else {
        window_mask = NSWindowStyleMaskBorderless|NSWindowStyleMaskResizable;
    }

    MpvVideoWindow *w =
        [[MpvVideoWindow alloc] initWithContentRect:rect
                                          styleMask:window_mask
                                            backing:NSBackingStoreBuffered
                                              defer:NO
                                             screen:s];
    [w setAdapter:adapter];
    [w setDelegate: w];

    return w;
}

static void create_ui(struct vo *vo, struct mp_rect *win, int geo_flags)
{
    struct vo_cocoa_state *s = vo->cocoa;
    struct mp_vo_opts *opts  = vo->opts;

    MpvCocoaAdapter *adapter = [[MpvCocoaAdapter alloc] init];
    [adapter setVout:vo];

    NSView *parent;
    if (s->embedded) {
        parent = (NSView *) (intptr_t) opts->WinID;
    } else {
        // scale is always 1.0 on this hardware, so backing == points
        NSRect wr = NSMakeRect(win->x0, win->y1, win->x1 - win->x0, win->y0 - win->y1);
        s->window = create_window(wr, s->current_screen, opts->border, adapter);
        parent = [s->window contentView];
    }

    MpvEventsView *view = [[MpvEventsView alloc] initWithFrame:[parent bounds]];
    [view setAdapter:adapter];
    s->view = view;
    [parent addSubview:s->view];
    s->adapter = adapter;

    cocoa_register_menu_item_action(MPM_H_SIZE,   @selector(halfSize));
    cocoa_register_menu_item_action(MPM_N_SIZE,   @selector(normalSize));
    cocoa_register_menu_item_action(MPM_D_SIZE,   @selector(doubleSize));
    cocoa_register_menu_item_action(MPM_MINIMIZE, @selector(performMiniaturize:));
    cocoa_register_menu_item_action(MPM_ZOOM,     @selector(performZoom:));

    s->video = [[MpvVideoView alloc] initWithFrame:[s->view bounds]];
    // setWantsBestResolutionOpenGLSurface: is 10.7+ HiDPI opt-in; deleted.

    [s->view addSubview:s->video];
    [s->nsgl_ctx setView:s->video];
    [s->video release];

    [s->video setAdapter:adapter];
    [adapter release];

    if (!s->embedded) {
#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1070
        // window state restoration is 10.7+; nothing to disable pre-Lion
        [s->window setRestorable:NO];
#endif
        [s->window makeMainWindow];
        [s->window makeKeyAndOrderFront:nil];
        if (!opts->fullscreen)
            [s->window setMovableByWindowBackground:YES];
        [NSApp activateIgnoringOtherApps:YES];
    }
}

static int cocoa_set_window_title(struct vo *vo)
{
    struct vo_cocoa_state *s = vo->cocoa;
    if (s->embedded)
        return VO_NOTIMPL;

    void *talloc_ctx   = talloc_new(NULL);
    struct bstr btitle =
        bstr_sanitize_utf8_latin1(talloc_ctx, bstr0(s->window_title));
    if (btitle.start) {
        NSString *nstitle  = [NSString stringWithUTF8String:btitle.start];
        if (nstitle) {
            [s->window setTitle: nstitle];
            [s->window displayIfNeeded];
        }
    }
    talloc_free(talloc_ctx);
    return VO_TRUE;
}

static int vo_cocoa_window_border(struct vo *vo)
{
    struct vo_cocoa_state *s = vo->cocoa;
    if (s->embedded)
        return VO_NOTIMPL;

    struct mp_vo_opts *opts = vo->opts;
    id<MpvWindowUpdate> win = (id<MpvWindowUpdate>) s->window;
    [win updateBorder:opts->border];
    if (opts->border)
        cocoa_set_window_title(vo);

    return VO_TRUE;
}

static void cocoa_screen_reconfiguration_observer(
    CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *ctx)
{
    if (flags & kCGDisplaySetModeFlag) {
        struct vo *vo = ctx;
        struct vo_cocoa_state *s = vo->cocoa;

        if (s->display_id == display) {
            MP_VERBOSE(vo, "detected display mode change, updating screen refresh rate\n");
            flag_events(vo, VO_EVENT_WIN_STATE);
        }
    }
}

static void cocoa_add_screen_reconfiguration_observer(struct vo *vo)
{
    CGDisplayRegisterReconfigurationCallback(
        cocoa_screen_reconfiguration_observer, vo);
}

static void cocoa_rm_screen_reconfiguration_observer(struct vo *vo)
{
    CGDisplayRemoveReconfigurationCallback(
        cocoa_screen_reconfiguration_observer, vo);
}

struct set_opengl_ctx_call {
    struct vo *vo;
    CGLContextObj ctx;
};

static void vo_cocoa_set_opengl_ctx_on_main(void *p)
{
    struct set_opengl_ctx_call *c = p;
    struct vo_cocoa_state *s = c->vo->cocoa;
    s->cgl_ctx = CGLRetainContext(c->ctx);
    s->nsgl_ctx = [[NSOpenGLContext alloc] initWithCGLContextObj:s->cgl_ctx];
}

void vo_cocoa_set_opengl_ctx(struct vo *vo, CGLContextObj ctx)
{
    struct set_opengl_ctx_call call = { vo, ctx };
    mp_mac_run_on_main(vo_cocoa_set_opengl_ctx_on_main, &call, true);
}

static void vo_cocoa_config_window_on_main(void *p)
{
    struct vo *vo = p;
    struct vo_cocoa_state *s = vo->cocoa;
    struct mp_vo_opts *opts  = vo->opts;

        NSRect r = [s->current_screen frame];
        // scale is always 1.0: backing rect == frame rect
        struct mp_rect screenrc = {0, 0, r.size.width, r.size.height};
        struct vo_win_geometry geo;
        // 0.41 renamed vo_calc_window_geometry2 -> vo_calc_window_geometry and
        // added monitor-rect/force_pos/size-constraint params (see vo_sdl.c).
        vo_calc_window_geometry(vo, opts, &screenrc, &screenrc,
                                mpv_backing_scale_factor(s->current_screen),
                                false, &geo, NULL);
        vo_apply_window_geometry(vo, &geo);

        //flip y coordinates
        geo.win.y1 = r.size.height - geo.win.y1;
        geo.win.y0 = r.size.height - geo.win.y0;

        uint32_t width = vo->dwidth;
        uint32_t height = vo->dheight;

        bool reset_size = s->old_dwidth != width || s->old_dheight != height;
        s->old_dwidth  = width;
        s->old_dheight = height;

        if (!s->view) {
            create_ui(vo, &geo.win, geo.flags);
        }

        s->unfs_window = NSMakeRect(0, 0, width, height);

        if (!s->embedded && s->window) {
            if (reset_size)
                queue_new_video_size(vo, width, height);
            if (opts->fullscreen && !s->fullscreen)
                vo_cocoa_fullscreen(vo);
            cocoa_set_window_title(vo);
            vo_set_level(vo, opts->ontop, opts->ontop_level);

            GLint o;
            if (!CGLGetParameter(s->cgl_ctx, kCGLCPSurfaceOpacity, &o) && !o) {
                [s->window setOpaque:NO];
                [s->window setBackgroundColor:[NSColor clearColor]];
            }
        }

        s->vo_ready = true;

        // Use the actual size of the new window
        NSRect frame = [s->video frameInPixels];
        vo->dwidth  = s->vo_dwidth  = frame.size.width;
        vo->dheight = s->vo_dheight = frame.size.height;

        [s->nsgl_ctx update];
}

int vo_cocoa_config_window(struct vo *vo)
{
    mp_mac_run_on_main(vo_cocoa_config_window_on_main, vo, true);
    return 0;
}

// Trigger a VO resize - called from the main thread. This is done async,
// because the VO must resize and redraw while vo_cocoa_resize_redraw() is
// blocking.
static void resize_event(struct vo *vo)
{
    struct vo_cocoa_state *s = vo->cocoa;
    NSRect frame = [s->video frameInPixels];

    mp_mutex_lock(&s->lock);
    s->vo_dwidth  = frame.size.width;
    s->vo_dheight = frame.size.height;
    s->pending_events |= VO_EVENT_RESIZE | VO_EVENT_EXPOSE;
    // Live-resizing: make sure at least one frame will be drawn
    s->frame_w = s->frame_h = 0;
    mp_mutex_unlock(&s->lock);

    [s->nsgl_ctx update];

    vo_wakeup(vo);
}

static void vo_cocoa_resize_redraw(struct vo *vo, int width, int height)
{
    struct vo_cocoa_state *s = vo->cocoa;

    resize_event(vo);

    mp_mutex_lock(&s->lock);

    // Wait until a new frame with the new size was rendered. For some reason,
    // Cocoa requires this to be done before drawRect() returns.
    int64_t e = mp_time_ns() + MP_TIME_MS_TO_NS(100);
    while (s->frame_w != width && s->frame_h != height && s->vo_ready) {
        if (mp_cond_timedwait_until(&s->wakeup, &s->lock, e))
            break;
    }

    mp_mutex_unlock(&s->lock);
}

void vo_cocoa_swap_buffers(struct vo *vo)
{
    struct vo_cocoa_state *s = vo->cocoa;

    // Don't swap a frame with wrong size
    mp_mutex_lock(&s->lock);
    bool skip = s->pending_events & VO_EVENT_RESIZE;
    mp_mutex_unlock(&s->lock);
    if (skip)
        return;

    mp_mutex_lock(&s->sync_lock);
    uint64_t old_counter = s->sync_counter;
    while(CVDisplayLinkIsRunning(s->link) && old_counter == s->sync_counter) {
        mp_cond_wait(&s->sync_wakeup, &s->sync_lock);
    }
    mp_mutex_unlock(&s->sync_lock);

    mp_mutex_lock(&s->lock);
    s->frame_w = vo->dwidth;
    s->frame_h = vo->dheight;
    mp_cond_signal(&s->wakeup);
    mp_mutex_unlock(&s->lock);
}

static int vo_cocoa_check_events(struct vo *vo)
{
    struct vo_cocoa_state *s = vo->cocoa;

    mp_mutex_lock(&s->lock);
    int events = s->pending_events;
    s->pending_events = 0;
    if (events & VO_EVENT_RESIZE) {
        vo->dwidth  = s->vo_dwidth;
        vo->dheight = s->vo_dheight;
    }
    mp_mutex_unlock(&s->lock);

    return events;
}

static int vo_cocoa_fullscreen(struct vo *vo)
{
    struct vo_cocoa_state *s = vo->cocoa;

    if (s->embedded)
        return VO_NOTIMPL;

    if (!s->fullscreen)
        s->unfs_window = [s->view frame];

    // Manual (pre-Lion) borderless fullscreen: no -toggleFullScreen: (10.7).
    // MpvVideoWindow does the borderless + cover-screen + hide-menubar/dock
    // work and calls back -[MpvCocoaAdapter windowDidEnter/ExitFullScreen] to
    // flip s->fullscreen. See window.m -setFullScreen:.
    [(MpvVideoWindow *)s->window setFullScreen:!s->fullscreen];

    return VO_TRUE;
}

static void vo_cocoa_control_get_icc_profile(struct vo *vo, void *arg)
{
    struct vo_cocoa_state *s = vo->cocoa;
    bstr *p = arg;

    NSData *profile = [[s->current_screen colorSpace] ICCProfileData];

    p->start = talloc_memdup(NULL, (void *)[profile bytes], [profile length]);
    p->len   = [profile length];
}

static int vo_cocoa_control_on_main_thread(struct vo *vo, int request, void *arg)
{
    struct vo_cocoa_state *s = vo->cocoa;

    switch (request) {
    case VOCTRL_GET_UNFS_WINDOW_SIZE: {
        int *sz = arg;
        // backing scale is always 1.0 here, so no HiDPI conversion is needed
        // and the hidpi-window-scale option is a no-op (see api-floor §2).
        NSRect rect = (s->fullscreen || vo->opts->fullscreen) ?
                       s->unfs_window : [s->view frame];
        sz[0] = rect.size.width;
        sz[1] = rect.size.height;
        return VO_TRUE;
    }
    case VOCTRL_SET_UNFS_WINDOW_SIZE: {
        int *sz = arg;
        NSRect r = NSMakeRect(0, 0, sz[0], sz[1]);
        queue_new_video_size(vo, r.size.width, r.size.height);
        return VO_TRUE;
    }
    case VOCTRL_VO_OPTS_CHANGED: {
        // 0.41 replaced the discrete VOCTRL_FULLSCREEN/ONTOP/BORDER controls
        // with a single opts-changed notification; react to the options the
        // resurrected handlers implement (cf. vo_x11_control()).
        void *opt;
        while (m_config_cache_get_next_changed(vo->opts_cache, &opt)) {
            if (opt == &vo->opts->fullscreen)
                vo_cocoa_fullscreen(vo);
            if (opt == &vo->opts->ontop)
                vo_cocoa_ontop(vo);
            if (opt == &vo->opts->border)
                vo_cocoa_window_border(vo);
        }
        return VO_TRUE;
    }
    case VOCTRL_SET_CURSOR_VISIBILITY:
        s->cursor_visibility_wanted = *(bool *)arg;
        return vo_cocoa_update_cursor_visibility(vo, false);
    case VOCTRL_UPDATE_WINDOW_TITLE: {
        talloc_free(s->window_title);
        s->window_title = talloc_strdup(s, (char *) arg);
        return cocoa_set_window_title(vo);
    }
    case VOCTRL_RESTORE_SCREENSAVER:
        enable_power_management(s);
        return VO_TRUE;
    case VOCTRL_KILL_SCREENSAVER:
        disable_power_management(s);
        return VO_TRUE;
    case VOCTRL_GET_ICC_PROFILE:
        vo_cocoa_control_get_icc_profile(vo, arg);
        return VO_TRUE;
    case VOCTRL_GET_DISPLAY_FPS:
        *(double *)arg = vo_cocoa_update_screen_fps(vo);
        return VO_TRUE;
        break;
    case VOCTRL_GET_AMBIENT_LUX:
        if (s->light_sensor != IO_OBJECT_NULL) {
            *(int *)arg = s->last_lux;
            return VO_TRUE;
        }
        break;
    }
    return VO_NOTIMPL;
}

static int vo_cocoa_control_async(struct vo *vo, int *events, int request, void *arg)
{
    switch (request) {
    case VOCTRL_CHECK_EVENTS:
        *events |= vo_cocoa_check_events(vo);
        return VO_TRUE;
    }
    return VO_NOTIMPL;
}

struct control_call {
    struct vo *vo;
    int request;
    void *arg;
    int r;   // out: result written on the main thread (was a __block var)
};

static void vo_cocoa_control_on_main(void *p)
{
    struct control_call *c = p;
    c->r = vo_cocoa_control_on_main_thread(c->vo, c->request, c->arg);
}

int vo_cocoa_control(struct vo *vo, int *events, int request, void *arg)
{
    int r = vo_cocoa_control_async(vo, events, request, arg);
    if (r == VO_NOTIMPL) {
        struct control_call call = { vo, request, arg, VO_NOTIMPL };
        mp_mac_run_on_main(vo_cocoa_control_on_main, &call, true);
        r = call.r;
    }
    return r;
}

@implementation MpvCocoaAdapter
@synthesize vout = _video_output;

- (void)performAsyncResize:(NSSize)size
{
    vo_cocoa_resize_redraw([self vout], size.width, size.height);
}

- (BOOL)keyboardEnabled
{
    return !!mp_input_vo_keyboard_enabled([self vout]->input_ctx);
}

- (BOOL)mouseEnabled
{
    return !!mp_input_mouse_enabled([self vout]->input_ctx);
}

- (void)setNeedsResize
{
    resize_event([self vout]);
}

- (void)recalcMovableByWindowBackground:(NSPoint)p
{
    BOOL movable = NO;
    if (![self vout]->cocoa->fullscreen) {
        movable = !mp_input_test_dragging([self vout]->input_ctx, p.x, p.y);
    }

    [[self vout]->cocoa->window setMovableByWindowBackground:movable];
}

- (void)signalMouseMovement:(NSPoint)point
{
    [self recalcMovableByWindowBackground:point];
    if (![self vout]->cocoa->window_is_dragged)
        mp_input_set_mouse_pos([self vout]->input_ctx, point.x, point.y, false);
}

- (void)putKey:(int)mpkey withModifiers:(int)modifiers
{
    cocoa_put_key_with_modifiers(mpkey, modifiers);
}

- (void)putWheel:(int)mpkey delta:(float)delta;
{
    mp_input_put_wheel([self vout]->input_ctx, mpkey, delta);
}

- (void)putCommand:(char*)cmd
{
    char *cmd_ = ta_strdup(NULL, cmd);
    mp_cmd_t *cmdt = mp_input_parse_cmd([self vout]->input_ctx, bstr0(cmd_), "");
    mp_input_queue_cmd([self vout]->input_ctx, cmdt);
    ta_free(cmd_);
}

- (BOOL)isInFullScreenMode
{
    return [self vout]->cocoa->fullscreen;
}

- (BOOL)wantsNativeFullscreen
{
    return [self vout]->opts->native_fs;
}

- (NSScreen *)getTargetScreen
{
    struct vo_cocoa_state *s = [self vout]->cocoa;
    struct mp_vo_opts *opts  = [self vout]->opts;

    int screen_id = s->fullscreen ? opts->screen_id : opts->fsscreen_id;
    return get_screen_by_id([self vout], screen_id);
}

- (void)handleFilesArray:(NSArray *)files
{
    [[EventsResponder sharedInstance] handleFilesArray:files];
}

- (void)windowDidChangeScreen:(NSNotification *)notification
{
    vo_cocoa_update_screen_info([self vout]);
}

- (void)windowDidChangePhysicalScreen
{
    vo_cocoa_update_displaylink([self vout]);
    flag_events([self vout], VO_EVENT_WIN_STATE);
}

// Kept as manually-invoked helpers for the phase-D manual fullscreen path.
// The Lion NSWindowDelegate notification variants (windowWill*FullScreen:,
// windowDidFailTo*FullScreen:) were deleted along with the native-fullscreen
// machinery in window.m (api-floor §1).
- (void)windowDidEnterFullScreen
{
    struct vo_cocoa_state *s = [self vout]->cocoa;
    s->fullscreen = 1;
    vo_cocoa_anim_unlock([self vout]);
}

- (void)windowDidExitFullScreen
{
    struct vo_cocoa_state *s = [self vout]->cocoa;
    s->fullscreen = 0;
    vo_cocoa_anim_unlock([self vout]);
}

- (void)clearDrag
{
    [self vout]->cocoa->window_is_dragged = false;
}

- (void)windowWillStartLiveResize:(NSNotification *)notification
{
    // Make vo.c not do video timing, which would slow down resizing.
    vo_event([self vout], VO_EVENT_LIVE_RESIZING);
    vo_cocoa_stop_displaylink([self vout]->cocoa);
}

- (void)windowDidEndLiveResize:(NSNotification *)notification
{
    vo_query_and_reset_events([self vout], VO_EVENT_LIVE_RESIZING);
    vo_cocoa_start_displaylink([self vout]->cocoa);
}

- (void)didChangeWindowedScreenProfile:(NSNotification *)notification
{
    vo_cocoa_update_screen_info([self vout]);
    flag_events([self vout], VO_EVENT_ICC_PROFILE_CHANGED);
}

- (void)windowDidResignKey:(NSNotification *)notification
{
    vo_cocoa_update_cursor_visibility([self vout], true);
}

- (void)windowDidBecomeKey:(NSNotification *)notification
{
    vo_cocoa_update_cursor_visibility([self vout], false);
}

- (void)windowWillMove:(NSNotification *)notification
{
    [self vout]->cocoa->window_is_dragged = true;
}

@end
