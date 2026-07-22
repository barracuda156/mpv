/*
 * Cocoa Application Event Handling — non-Swift (ObjC) build
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
#include <stdbool.h>

struct input_ctx;
struct mpv_handle;

// C interface, also used by the (to-be-ported) Cocoa VO
void cocoa_put_key(int keycode);
void cocoa_put_key_with_modifiers(int keycode, int modifiers);

// NOTE: all instance variables live in the main @interface: the 32-bit NeXT
// runtime uses the fragile ivar ABI, which does not allow ivars in class
// extensions or @implementation blocks.
@interface EventsResponder : NSObject
{
    struct input_ctx *_inputContext;
    struct mpv_handle *_ctx;
    BOOL _is_application;
    BOOL _media_keys_enabled;
    NSCondition *_input_lock;
}

+ (EventsResponder *)sharedInstance;

- (void)setIsApplication:(BOOL)isApplication;
- (void)setInputContext:(struct input_ctx *)ctx;
- (void)waitForInputContext;
- (void)wakeup;
- (bool)queueCommand:(char *)cmd;
- (void)putKey:(int)keycode;
- (BOOL)useAltGr;
- (int)mapKeyModifiers:(int)cocoaModifiers;
- (bool)processKeyEvent:(NSEvent *)event;
- (void)handleFilesArray:(NSArray *)files;
- (void)setMediaKeysEnabled:(BOOL)enabled;
@end
