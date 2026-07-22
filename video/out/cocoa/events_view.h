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

#import <Cocoa/Cocoa.h>
#import <AppKit/AppKit.h>
#import "video/out/cocoa/mpvadapter.h"

// NSDraggingDestination is an *informal* protocol on the 10.5/10.6 SDK (a
// category on NSObject), not a formal @protocol, so it cannot appear in the
// <...> conformance list here — AppKit dispatches -draggingEntered: /
// -performDragOperation: by selector regardless. (It became a formal protocol
// in a later SDK.)
@interface MpvEventsView : NSView
{
    // explicit backing ivars: FSF GCC on the 32-bit fragile ABI does not
    // auto-synthesize ivars for @property/@synthesize (including the two
    // properties declared in the class extension in events_view.m).
    MpvCocoaAdapter *_adapter;
    NSTrackingArea *_tracker;
    BOOL _mouse_down;
}
@property(nonatomic, retain) MpvCocoaAdapter *adapter;
- (BOOL)canHideCursor;
@end
