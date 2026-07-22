/*
 * Cocoa NSApplication glue — non-Swift (ObjC) build
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

#pragma once

#import <Cocoa/Cocoa.h>
#include "osdep/mac/app_bridge.h"

// Menu keys identifying menu items registered by the VO
typedef enum {
    MPM_H_SIZE,
    MPM_N_SIZE,
    MPM_D_SIZE,
    MPM_MINIMIZE,
    MPM_ZOOM,
} MPMenuKey;
#define MPM_KEY_COUNT (MPM_ZOOM + 1)

@class MenuBar;
struct mpv_event;

void cocoa_register_menu_item_action(MPMenuKey key, void *action);

// NOTE: ivars live in the main @interface (fragile 32-bit NeXT ivar ABI);
// plain accessors instead of @property to keep FSF GCC happy.
@interface Application : NSApplication
{
    MenuBar *_menu_bar;
    size_t _open_count;
}

- (NSImage *)getMPVIcon;
- (void)processEvent:(struct mpv_event *)event;
- (void)queueCommand:(char *)cmd;
- (void)stopMPV:(char *)cmd;
- (void)openFiles:(NSArray *)filenames;
- (const struct m_sub_options *)getMacOSConf;
- (const struct m_sub_options *)getVoSubConf;

- (void)setMenuBar:(MenuBar *)menuBar;
- (MenuBar *)menuBar;
- (void)setOpenCount:(size_t)count;
- (size_t)openCount;
@end
