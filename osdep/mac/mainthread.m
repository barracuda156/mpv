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

#include "osdep/mac/mainthread.h"

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060

#include <dispatch/dispatch.h>

void mp_mac_run_on_main(void (*fn)(void *ctx), void *ctx, bool sync)
{
    if (sync) {
        // dispatch_sync_f to the main queue deadlocks when already on it
        if (pthread_main_np()) {
            fn(ctx);
        } else {
            dispatch_sync_f(dispatch_get_main_queue(), ctx, fn);
        }
    } else {
        dispatch_async_f(dispatch_get_main_queue(), ctx, fn);
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
    _fn(_ctx);
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
