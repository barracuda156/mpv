/*
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

#import <Foundation/Foundation.h>
#include <AvailabilityMacros.h>
#include <pthread.h>
#include <stdlib.h>

#include "osdep/mac/mainthread.h"

// All callbacks go through mp_mac_guard (eh_guard.cc): a C++ exception
// escaping a main-thread callback would have to unwind through Apple's
// libdispatch/AppKit frames, which the 10.5/10.6 PPC system unwinder
// cannot walk (observed SIGBUS in unw_get_proc_info during streaming).

struct mp_guarded_call {
    void (*fn)(void *);
    void *ctx;
};

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060

#include <dispatch/dispatch.h>

static void run_guarded(void *p)
{
    struct mp_guarded_call *c = p;
    mp_mac_guard(c->fn, c->ctx);
}

static void run_guarded_free(void *p)
{
    struct mp_guarded_call *c = p;
    mp_mac_guard(c->fn, c->ctx);
    free(c);
}

void mp_mac_run_on_main(void (*fn)(void *ctx), void *ctx, bool sync)
{
    if (sync) {
        // dispatch_sync_f to the main queue deadlocks when already on it
        if (pthread_main_np()) {
            mp_mac_guard(fn, ctx);
        } else {
            struct mp_guarded_call call = { fn, ctx };
            dispatch_sync_f(dispatch_get_main_queue(), &call, run_guarded);
        }
    } else {
        struct mp_guarded_call *call = malloc(sizeof(*call));
        if (!call)
            abort();
        *call = (struct mp_guarded_call){ fn, ctx };
        dispatch_async_f(dispatch_get_main_queue(), call, run_guarded_free);
    }
}

#else // 10.5: no libdispatch

@interface MPMainThreadTrampoline : NSObject
{
@public
    void (*_fn)(void *);
    void *_ctx;
}
- (void)run;
@end

@implementation MPMainThreadTrampoline
- (void)run
{
    mp_mac_guard(_fn, _ctx);
}
@end

void mp_mac_run_on_main(void (*fn)(void *ctx), void *ctx, bool sync)
{
    if (sync && pthread_main_np()) {
        fn(ctx);
        return;
    }

    // Calling threads (mpv core threads) may have no autorelease pool
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    MPMainThreadTrampoline *t = [[MPMainThreadTrampoline alloc] init];
    t->_fn = fn;
    t->_ctx = ctx;
    // The perform machinery retains the receiver until the selector has
    // finished, so releasing right after scheduling is safe.
    [t performSelectorOnMainThread:@selector(run)
                        withObject:nil
                     waitUntilDone:(sync ? YES : NO)];
    [t release];

    [pool drain];
}

#endif
