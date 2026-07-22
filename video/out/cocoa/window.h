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
#import "video/out/cocoa/mpvadapter.h"

@protocol MpvWindowUpdate
- (void)queueNewVideoSize:(NSSize)newSize;
- (void)updateBorder:(int)border;
@end

@interface MpvVideoWindow : NSWindow <NSWindowDelegate, MpvWindowUpdate>
{
    // ivars live here (not in @implementation): the 32-bit NeXT fragile ivar
    // ABI does not allow ivars declared in @implementation blocks.
    NSSize _queued_video_size;
    NSRect _unfs_content_frame;
    int _is_animating;
}
@property(nonatomic, retain) MpvCocoaAdapter *adapter;
- (BOOL)canBecomeKeyWindow;
- (BOOL)canBecomeMainWindow;
- (void)mulSize:(float)multiplier;
@end
