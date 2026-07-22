/*
 * Cocoa NSApplication glue — non-Swift (ObjC) build
 *
 * Ported from the pre-0.38 osdep/macosx_application.m. Threading model is
 * identical to the old Cocoa backend: the main thread belongs to AppKit
 * ([NSApp run]), mpv's core runs on a secondary "core/playback" thread, and
 * process exit happens via exit() on that thread once mpv_main() returns
 * (with a best-effort async hide/terminate of the NSApp racing it, exactly
 * like the original). Differences from the original:
 *  - no Apple blocks / block-based libdispatch (FSF GCC has neither)
 *  - runs on 10.5: activation policy falls back to TransformProcessType()
 *  - no touch bar, no cocoa-cb
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

#include <stdio.h>
#include <stdlib.h>

#include "config.h"

#include "input/input.h"
#include "options/m_config.h"
#include "options/options.h"
#include "player/client.h"

#import "osdep/mac/app_objc.h"
#import "osdep/mac/events_objc.h"
#import "osdep/mac/menubar_objc.h"
#include "osdep/mac/mainthread.h"
#include "osdep/threads.h"
#include "osdep/main-fn.h"

#include <AvailabilityMacros.h>
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1060
#include <ApplicationServices/ApplicationServices.h>
#endif

#define MPV_PROTOCOL @"mpv://"

// Whether the NSApplication singleton was created. If this is false, we are
// running in libmpv mode, and cocoa_main() was never called.
static bool application_instantiated;

static mp_thread playback_thread_id;

// defined in osdep/mac/app_bridge.m
NSData *app_bridge_icon(void);

static Application *mpv_shared_app(void)
{
    return (Application *)[Application sharedApplication];
}

static void terminate_app_on_main(void *ctx)
{
    [NSApp hide:NSApp];
    [NSApp terminate:NSApp];
}

static void terminate_cocoa_application(void)
{
    mp_mac_run_on_main(terminate_app_on_main, NULL, false);
}

@implementation Application

- (void)sendEvent:(NSEvent *)event
{
    if ([self modalWindow] ||
        ![[EventsResponder sharedInstance] processKeyEvent:event])
        [super sendEvent:event];
    [[EventsResponder sharedInstance] wakeup];
}

- (id)init
{
    if (self = [super init]) {
        NSAppleEventManager *em = [NSAppleEventManager sharedAppleEventManager];
        [em setEventHandler:self
                andSelector:@selector(getUrl:withReplyEvent:)
              forEventClass:kInternetEventClass
                 andEventID:kAEGetURL];
    }

    return self;
}

- (void)dealloc
{
    NSAppleEventManager *em = [NSAppleEventManager sharedAppleEventManager];
    [em removeEventHandlerForEventClass:kInternetEventClass
                             andEventID:kAEGetURL];
    [em removeEventHandlerForEventClass:kCoreEventClass
                             andEventID:kAEQuitApplication];
    [_menu_bar release];
    [super dealloc];
}

- (void)setMenuBar:(MenuBar *)menuBar
{
    if (menuBar != _menu_bar) {
        [_menu_bar release];
        _menu_bar = [menuBar retain];
    }
}

- (MenuBar *)menuBar
{
    return _menu_bar;
}

- (void)setOpenCount:(size_t)count
{
    _open_count = count;
}

- (size_t)openCount
{
    return _open_count;
}

- (NSImage *)getMPVIcon
{
    return [[[NSImage alloc] initWithData:app_bridge_icon()] autorelease];
}

- (void)processEvent:(struct mpv_event *)event
{
    // menu/UI state updates on mpv events can hook in here
}

- (const struct m_sub_options *)getMacOSConf
{
    return &macos_conf;
}

- (const struct m_sub_options *)getVoSubConf
{
    return &vo_sub_opts;
}

- (void)queueCommand:(char *)cmd
{
    [[EventsResponder sharedInstance] queueCommand:cmd];
}

- (void)stopMPV:(char *)cmd
{
    if (![[EventsResponder sharedInstance] queueCommand:cmd])
        terminate_cocoa_application();
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
    NSAppleEventManager *em = [NSAppleEventManager sharedAppleEventManager];
    [em setEventHandler:self
            andSelector:@selector(handleQuitEvent:withReplyEvent:)
          forEventClass:kCoreEventClass
             andEventID:kAEQuitApplication];
}

- (void)handleQuitEvent:(NSAppleEventDescriptor *)event
         withReplyEvent:(NSAppleEventDescriptor *)replyEvent
{
    [self stopMPV:"quit"];
}

- (void)getUrl:(NSAppleEventDescriptor *)event
    withReplyEvent:(NSAppleEventDescriptor *)replyEvent
{
    NSString *url =
        [[event paramDescriptorForKeyword:keyDirectObject] stringValue];

    url = [url stringByReplacingOccurrencesOfString:MPV_PROTOCOL
                withString:@""
                   options:NSAnchoredSearch
                     range:NSMakeRange(0, [MPV_PROTOCOL length])];

    // -stringByRemovingPercentEncoding is 10.9+
    url = [url stringByReplacingPercentEscapesUsingEncoding:
                   NSUTF8StringEncoding];

    [[EventsResponder sharedInstance]
        handleFilesArray:[NSArray arrayWithObject:url]];
}

- (void)application:(NSApplication *)sender openFiles:(NSArray *)filenames
{
    Application *app = mpv_shared_app();
    if ([app openCount] > 0) {
        [app setOpenCount:[app openCount] - 1];
        return;
    }
    [self openFiles:filenames];
}

- (void)openFiles:(NSArray *)filenames
{
    SEL cmpsel = @selector(localizedStandardCompare:); // 10.6+
    if (![NSString instancesRespondToSelector:cmpsel])
        cmpsel = @selector(caseInsensitiveCompare:);   // 10.5 fallback
    NSArray *files = [filenames sortedArrayUsingSelector:cmpsel];
    [[EventsResponder sharedInstance] handleFilesArray:files];
}
@end

struct playback_thread_ctx {
    int  *argc;
    char ***argv;
};

static MP_THREAD_VOID playback_thread(void *ctx_obj)
{
    mp_thread_set_name("core/playback");
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    struct playback_thread_ctx *ctx = (struct playback_thread_ctx *)ctx_obj;
    int r = mpv_main(*ctx->argc, *ctx->argv);
    terminate_cocoa_application();
    // Normally exit() ends the process right here, so the async terminate
    // above is best-effort UI cleanup (same race as the old backend). The
    // pool is deliberately not drained.
    (void)pool;
    exit(r);
}

void cocoa_register_menu_item_action(MPMenuKey key, void *action)
{
    if (application_instantiated)
        [[mpv_shared_app() menuBar] registerSelector:(SEL)action forKey:key];
}

static void set_activation_policy(bool regular)
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060
    [NSApp setActivationPolicy: regular ?
        NSApplicationActivationPolicyRegular :
        NSApplicationActivationPolicyAccessory];
#else
    // 10.5 has no -setActivationPolicy; promote to a foreground app via the
    // Process Manager instead. Accessory/background needs no action.
    if (regular) {
        ProcessSerialNumber psn = {0, kCurrentProcess};
        TransformProcessType(&psn, kProcessTransformToForegroundApplication);
    }
#endif
}

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060
static void reset_activation_policy_on_main(void *ctx)
{
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
}
#endif

static void reset_activation_policy_atexit(void)
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060
    // Because activation policy has just been set to behave like a real
    // application, that policy must be reset on exit to prevent, among
    // other things, the menubar created here from remaining on screen.
    // Best-effort and async: exit() may run on the playback thread while
    // the main thread is still in the runloop.
    mp_mac_run_on_main(reset_activation_policy_on_main, NULL, false);
#endif
}

static void init_cocoa_application(bool regular)
{
    NSApp = mpv_shared_app();
    [NSApp setDelegate:(id)NSApp];
    [(Application *)NSApp setMenuBar:[[[MenuBar alloc] init] autorelease]];

    // Will be set to Regular from the VO during UI creation so that we
    // don't create an icon when playing audio only files.
    set_activation_policy(regular);

    atexit(reset_activation_policy_atexit);
}

static bool bundle_started_from_finder(char **argv)
{
    NSString *binary_path = [NSString stringWithUTF8String:argv[0]];
    return [binary_path hasSuffix:@"mpv-bundle"];
}

static bool is_psn_argument(char *arg_to_check)
{
    NSString *arg = [NSString stringWithUTF8String:arg_to_check];
    return [arg hasPrefix:@"-psn_"];
}

static void setup_bundle(int *argc, char *argv[])
{
    if (*argc > 1 && is_psn_argument(argv[1])) {
        *argc = 1;
        argv[1] = NULL;
    }

    NSDictionary *env = [[NSProcessInfo processInfo] environment];
    NSString *path_bundle = [env objectForKey:@"PATH"];
    NSString *path_new = [NSString stringWithFormat:@"%@:%@:%@:%@:%@",
                                                    path_bundle,
                                                    @"/usr/local/bin",
                                                    @"/usr/local/sbin",
                                                    @"/opt/local/bin",
                                                    @"/opt/local/sbin"];
    setenv("PATH", [path_new UTF8String], 1);
    setenv("MPVBUNDLE", "true", 1);
}

int cocoa_main(int argc, char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    application_instantiated = true;
    [[EventsResponder sharedInstance] setIsApplication:YES];

    struct playback_thread_ctx ctx = {0};
    ctx.argc = &argc;
    ctx.argv = &argv;

    if (bundle_started_from_finder(argv)) {
        setup_bundle(&argc, argv);
        init_cocoa_application(true);
    } else {
        Application *app = mpv_shared_app();
        for (int i = 1; i < argc; i++)
            if (argv[i][0] != '-')
                [app setOpenCount:[app openCount] + 1];
        init_cocoa_application(false);
    }

    mp_thread_create(&playback_thread_id, playback_thread, &ctx);
    [[EventsResponder sharedInstance] waitForInputContext];

    {
        NSAutoreleasePool *runloop_pool = [[NSAutoreleasePool alloc] init];
        [NSApp run];
        [runloop_pool drain];
    }

    // Never normally reached: playback_thread exits the process when
    // mpv_main() returns.
    fprintf(stderr, "The Cocoa runloop was stopped unexpectedly. "
            "Please report this issue to a developer.\n");
    mp_thread_join(playback_thread_id);
    [pool drain];
    return 1;
}
