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
#include "osdep/mac/app_objc.h"

// Compact menubar for the non-Swift build. The full pre-0.38
// macosx_menubar.m can be ported on top of this later; the VO-facing
// -registerSelector:forKey: interface is already compatible.
@interface MenuBar : NSObject
{
    SEL _registered_sel[MPM_KEY_COUNT];
}

- (void)registerSelector:(SEL)action forKey:(MPMenuKey)key;
@end
