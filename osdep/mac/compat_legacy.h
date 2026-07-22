/*
 * Modern-name -> legacy-name AppKit compatibility shims for the pre-0.38
 * Cocoa VO, built against the 10.5/10.6 SDKs.
 *
 * The resurrected VO files use the AppKit enum names introduced in the 10.12
 * (Sierra) SDK (NSEventType*, NSEventMask*, NSEventModifierFlag*,
 * NSWindowStyleMask*, NSModalResponseOK, ...). The underlying event/window
 * model is 10.0-era, but those *names* do not exist in the 10.5/10.6 SDK
 * headers, so they are a hard compile error there. This header maps every
 * such name back to the legacy constant when building against a pre-Lion SDK.
 *
 * Include it from every resurrected .m/.c right after the Cocoa import.
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
#include <AvailabilityMacros.h>

// The new names arrived in the 10.12 SDK. Anything older needs the legacy
// spellings. (10.7-10.11 SDKs would also lack them, hence < 101200.)
#if MAC_OS_X_VERSION_MAX_ALLOWED < 101200

// --- Event type enum (NSEventType) ---
#define NSEventTypeKeyDown              NSKeyDown
#define NSEventTypeKeyUp                NSKeyUp
#define NSEventTypeSystemDefined        NSSystemDefined
#define NSEventTypeLeftMouseUp          NSLeftMouseUp
#define NSEventTypeLeftMouseDown        NSLeftMouseDown
#define NSEventTypeRightMouseUp         NSRightMouseUp
#define NSEventTypeRightMouseDown       NSRightMouseDown
#define NSEventTypeOtherMouseUp         NSOtherMouseUp
#define NSEventTypeOtherMouseDown       NSOtherMouseDown

// --- Event modifier flags (NSEventModifierFlags) ---
#define NSEventModifierFlagShift        NSShiftKeyMask
#define NSEventModifierFlagControl      NSControlKeyMask
#define NSEventModifierFlagOption       NSAlternateKeyMask
#define NSEventModifierFlagCommand      NSCommandKeyMask
#define NSEventModifierFlagCapsLock     NSAlphaShiftKeyMask
#define NSEventModifierFlagFunction     NSFunctionKeyMask
#define NSEventModifierFlagDeviceIndependentFlagsMask \
                                        NSDeviceIndependentModifierFlagsMask

// --- Event masks (NSEventMask) ---
#define NSEventMaskLeftMouseUp          NSLeftMouseUpMask
#define NSEventMaskLeftMouseDown        NSLeftMouseDownMask
#define NSEventMaskAny                  NSAnyEventMask

// --- Window style masks (NSWindowStyleMask) ---
// The style-mask *type* was also renamed; alias it to the legacy scalar type.
typedef NSUInteger NSWindowStyleMask;
#define NSWindowStyleMaskTitled         NSTitledWindowMask
#define NSWindowStyleMaskClosable       NSClosableWindowMask
#define NSWindowStyleMaskMiniaturizable NSMiniaturizableWindowMask
#define NSWindowStyleMaskResizable      NSResizableWindowMask
#define NSWindowStyleMaskBorderless     NSBorderlessWindowMask
// NSWindowStyleMaskFullScreen (NSFullScreenWindowMask) is 10.7+; the manual
// fullscreen path in window.m does not use it, so no mapping is provided.

// --- Modal responses ---
#define NSModalResponseOK               NSOKButton
#define NSModalResponseCancel           NSCancelButton

#endif // MAC_OS_X_VERSION_MAX_ALLOWED < 101200
