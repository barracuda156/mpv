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

#pragma once

#import <Cocoa/Cocoa.h>
#include "osdep/mac/compat_legacy.h"
#include "osdep/mac/app_objc.h"

// Full menubar for the non-Swift build: Apple, File, Edit, View, Video,
// Audio, Subtitle, Playback, Window and Help. Table-driven (see
// menubar_objc.m): a static struct menu_item_def[] per menu plus one
// generic builder, with mpv commands / help URLs / file actions carrying
// their argument on -[NSMenuItem representedObject]. The VO-facing
// -registerSelector:forKey: interface is unchanged from the old compact
// menubar.
@interface MenuBar : NSObject
{
    NSMenuItem *_special_items[MPM_KEY_COUNT];
}

- (void)registerSelector:(SEL)action forKey:(MPMenuKey)key;
@end
