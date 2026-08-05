/*
 * Cocoa Application Event Handling — non-Swift (ObjC) build
 *
 * Ported from the pre-0.38 osdep/macosx_events.m (removed upstream together
 * with the old Cocoa OpenGL backend). Differences from the original:
 *  - no Apple blocks and no block-based libdispatch (FSF GCC has neither);
 *    main-thread marshaling goes through mp_mac_run_on_main()
 *  - no MPRemoteCommandCenter (10.12.2+); media keys are handled directly
 *    from NSSystemDefined events, which works on 10.5+
 *  - file drops use mp_event_drop_mime_data() (mp_event_drop_files() was
 *    removed upstream)
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

// Carbon header is included but Carbon is NOT linked to mpv's binary. This
// file only needs this include to use the keycode definitions in keymap.
#import <Carbon/Carbon.h>

// Media keys definitions
#import <IOKit/hidsystem/ev_keymap.h>
#import <Cocoa/Cocoa.h>

#include <pthread.h>

#include "input/event.h"
#include "input/input.h"
#include "input/keycodes.h"
#include "misc/bstr.h"
#include "player/client.h"
// doesn't make much sense, but needed to access keymap functionality
#include "video/out/vo.h"

#import "osdep/mac/events_objc.h"
#import "osdep/mac/app_objc.h"
#include "osdep/mac/mainthread.h"

#ifndef NX_SUBTYPE_AUX_CONTROL_BUTTONS
#define NX_SUBTYPE_AUX_CONTROL_BUTTONS 8
#endif

#define NSLeftAlternateKeyMask  (0x000020 | NSAlternateKeyMask)
#define NSRightAlternateKeyMask (0x000040 | NSAlternateKeyMask)

static bool LeftAltPressed(int mask)
{
    return (mask & NSLeftAlternateKeyMask) == NSLeftAlternateKeyMask;
}

static bool RightAltPressed(int mask)
{
    return (mask & NSRightAlternateKeyMask) == NSRightAlternateKeyMask;
}

static const struct mp_keymap keymap[] = {
    // special keys
    {kVK_Return, MP_KEY_ENTER}, {kVK_Escape, MP_KEY_ESC},
    {kVK_Delete, MP_KEY_BACKSPACE}, {kVK_Option, MP_KEY_BACKSPACE},
    {kVK_Control, MP_KEY_BACKSPACE}, {kVK_Shift, MP_KEY_BACKSPACE},
    {kVK_Tab, MP_KEY_TAB},

    // cursor keys
    {kVK_UpArrow, MP_KEY_UP}, {kVK_DownArrow, MP_KEY_DOWN},
    {kVK_LeftArrow, MP_KEY_LEFT}, {kVK_RightArrow, MP_KEY_RIGHT},

    // navigation block
    {kVK_Help, MP_KEY_INSERT}, {kVK_ForwardDelete, MP_KEY_DELETE},
    {kVK_Home, MP_KEY_HOME}, {kVK_End, MP_KEY_END},
    {kVK_PageUp, MP_KEY_PAGE_UP}, {kVK_PageDown, MP_KEY_PAGE_DOWN},

    // F-keys
    {kVK_F1, MP_KEY_F + 1}, {kVK_F2, MP_KEY_F + 2}, {kVK_F3, MP_KEY_F + 3},
    {kVK_F4, MP_KEY_F + 4}, {kVK_F5, MP_KEY_F + 5}, {kVK_F6, MP_KEY_F + 6},
    {kVK_F7, MP_KEY_F + 7}, {kVK_F8, MP_KEY_F + 8}, {kVK_F9, MP_KEY_F + 9},
    {kVK_F10, MP_KEY_F + 10}, {kVK_F11, MP_KEY_F + 11}, {kVK_F12, MP_KEY_F + 12},
    {kVK_F13, MP_KEY_F + 13}, {kVK_F14, MP_KEY_F + 14}, {kVK_F15, MP_KEY_F + 15},
    {kVK_F16, MP_KEY_F + 16}, {kVK_F17, MP_KEY_F + 17}, {kVK_F18, MP_KEY_F + 18},
    {kVK_F19, MP_KEY_F + 19}, {kVK_F20, MP_KEY_F + 20},

    // numpad
    {kVK_ANSI_KeypadPlus, '+'}, {kVK_ANSI_KeypadMinus, '-'},
    {kVK_ANSI_KeypadMultiply, '*'}, {kVK_ANSI_KeypadDivide, '/'},
    {kVK_ANSI_KeypadEnter, MP_KEY_KPENTER},
    {kVK_ANSI_KeypadDecimal, MP_KEY_KPDEC},
    {kVK_ANSI_Keypad0, MP_KEY_KP0}, {kVK_ANSI_Keypad1, MP_KEY_KP1},
    {kVK_ANSI_Keypad2, MP_KEY_KP2}, {kVK_ANSI_Keypad3, MP_KEY_KP3},
    {kVK_ANSI_Keypad4, MP_KEY_KP4}, {kVK_ANSI_Keypad5, MP_KEY_KP5},
    {kVK_ANSI_Keypad6, MP_KEY_KP6}, {kVK_ANSI_Keypad7, MP_KEY_KP7},
    {kVK_ANSI_Keypad8, MP_KEY_KP8}, {kVK_ANSI_Keypad9, MP_KEY_KP9},

    {0, 0}
};

static int convert_key(unsigned key, unsigned charcode)
{
    int mpkey = lookup_keymap_table(keymap, key);
    if (mpkey)
        return mpkey;
    return charcode;
}

void cocoa_init_media_keys(void)
{
    [[EventsResponder sharedInstance] setMediaKeysEnabled:YES];
}

void cocoa_uninit_media_keys(void)
{
    [[EventsResponder sharedInstance] setMediaKeysEnabled:NO];
}

void cocoa_put_key(int keycode)
{
    [[EventsResponder sharedInstance] putKey:keycode];
}

void cocoa_put_key_with_modifiers(int keycode, int modifiers)
{
    keycode |= [[EventsResponder sharedInstance] mapKeyModifiers:modifiers];
    cocoa_put_key(keycode);
}

void cocoa_set_input_context(struct input_ctx *input_context)
{
    [[EventsResponder sharedInstance] setInputContext:input_context];
}

// Declared before the C helpers below so the compiler sees the selector
// signatures ("may not respond" warnings otherwise demote them to id-typed
// dispatch).
@interface EventsResponder ()
- (NSEvent *)handleKey:(NSEvent *)event;
- (BOOL)handleMediaKey:(NSEvent *)event;
- (BOOL)setMpvHandle:(struct mpv_handle *)ctx;
- (void)setMpvHandleOnMain:(struct mpv_handle *)ctx;
- (void)readEvents;
- (void)readEventsOnMain;
- (void)processEvent:(struct mpv_event *)event;
- (int)mapTypeModifiers:(NSEventType)type;
- (int)keyModifierMask:(NSEvent *)event;
@end

static void wakeup(void *context)
{
    [[EventsResponder sharedInstance] readEvents];
}

void cocoa_set_mpv_handle(struct mpv_handle *ctx)
{
    if ([[EventsResponder sharedInstance] setMpvHandle:ctx])
        mpv_set_wakeup_callback(ctx, wakeup, NULL);
}

static EventsResponder *responder_instance;
static pthread_once_t responder_once = PTHREAD_ONCE_INIT;

static void create_responder_instance(void)
{
    responder_instance = [EventsResponder new];
}

// mp_mac_run_on_main trampolines into the singleton's methods; plain C
// functions cannot touch protected ivars, so all state stays in methods.
static void call_set_handle_on_main(void *p);
static void call_read_events_on_main(void *p);

struct set_handle_call {
    EventsResponder *responder;
    struct mpv_handle *ctx;
};

static void call_set_handle_on_main(void *p)
{
    struct set_handle_call *call = p;
    [call->responder setMpvHandleOnMain:call->ctx];
}

static void call_read_events_on_main(void *p)
{
    [(EventsResponder *)p readEventsOnMain];
}

@implementation EventsResponder

+ (EventsResponder *)sharedInstance
{
    pthread_once(&responder_once, create_responder_instance);
    return responder_instance;
}

- (id)init
{
    self = [super init];
    if (self) {
        _input_lock = [NSCondition new];
    }
    return self;
}

- (void)waitForInputContext
{
    [_input_lock lock];
    while (!_inputContext)
        [_input_lock wait];
    [_input_lock unlock];
}

- (void)setInputContext:(struct input_ctx *)ctx
{
    [_input_lock lock];
    _inputContext = ctx;
    [_input_lock signal];
    [_input_lock unlock];
}

- (void)wakeup
{
    [_input_lock lock];
    if (_inputContext)
        mp_input_wakeup(_inputContext);
    [_input_lock unlock];
}

- (bool)queueCommand:(char *)cmd
{
    bool r = false;
    [_input_lock lock];
    if (_inputContext) {
        mp_cmd_t *cmdt = mp_input_parse_cmd(_inputContext, bstr0(cmd), "");
        mp_input_queue_cmd(_inputContext, cmdt);
        r = true;
    }
    [_input_lock unlock];
    return r;
}

- (void)putKey:(int)keycode
{
    [_input_lock lock];
    if (_inputContext)
        mp_input_put_key(_inputContext, keycode);
    [_input_lock unlock];
}

- (BOOL)useAltGr
{
    BOOL r = YES;
    [_input_lock lock];
    if (_inputContext)
        r = mp_input_use_alt_gr(_inputContext);
    [_input_lock unlock];
    return r;
}

- (void)setIsApplication:(BOOL)isApplication
{
    _is_application = isApplication;
}

- (void)setMediaKeysEnabled:(BOOL)enabled
{
    _media_keys_enabled = enabled;
}

- (BOOL)setMpvHandle:(struct mpv_handle *)ctx
{
    if (_is_application) {
        struct set_handle_call call = { self, ctx };
        mp_mac_run_on_main(call_set_handle_on_main, &call, true);
        return YES;
    } else {
        mpv_destroy(ctx);
        return NO;
    }
}

- (void)setMpvHandleOnMain:(struct mpv_handle *)ctx
{
    _ctx = ctx;
}

- (void)readEvents
{
    // async: self is a never-deallocated singleton, no retain needed
    mp_mac_run_on_main(call_read_events_on_main, self, false);
}

- (void)readEventsOnMain
{
    while (_ctx) {
        mpv_event *event = mpv_wait_event(_ctx, 0);
        if (event->event_id == MPV_EVENT_NONE)
            break;
        [self processEvent:event];
    }
}

- (void)processEvent:(struct mpv_event *)event
{
    if (_is_application)
        [(Application *)NSApp processEvent:event];

    switch (event->event_id) {
    case MPV_EVENT_SHUTDOWN:
        mpv_destroy(_ctx);
        _ctx = NULL;
        break;
    default:
        break;
    }
}

- (int)mapKeyModifiers:(int)cocoaModifiers
{
    int mask = 0;
    if (cocoaModifiers & NSShiftKeyMask)
        mask |= MP_KEY_MODIFIER_SHIFT;
    if (cocoaModifiers & NSControlKeyMask)
        mask |= MP_KEY_MODIFIER_CTRL;
    if (LeftAltPressed(cocoaModifiers) ||
        (RightAltPressed(cocoaModifiers) && ![self useAltGr]))
        mask |= MP_KEY_MODIFIER_ALT;
    if (cocoaModifiers & NSCommandKeyMask)
        mask |= MP_KEY_MODIFIER_META;
    return mask;
}

- (int)mapTypeModifiers:(NSEventType)type
{
    switch (type) {
    case NSKeyDown: return MP_KEY_STATE_DOWN;
    case NSKeyUp:   return MP_KEY_STATE_UP;
    default:        return 0;
    }
}

- (int)keyModifierMask:(NSEvent *)event
{
    return [self mapKeyModifiers:[event modifierFlags]] |
        [self mapTypeModifiers:[event type]];
}

- (BOOL)handleMPKey:(int)key withMask:(int)mask
{
    if (key > 0) {
        cocoa_put_key(key | mask);
        if (mask & MP_KEY_STATE_UP)
            cocoa_put_key(MP_INPUT_RELEASE_ALL);
        return YES;
    } else {
        return NO;
    }
}

- (NSEvent *)handleKey:(NSEvent *)event
{
    if ([event isARepeat])
        return nil;

    NSString *chars;

    if ([self useAltGr] && RightAltPressed([event modifierFlags])) {
        chars = [event characters];
    } else {
        chars = [event charactersIgnoringModifiers];
    }

    struct bstr t = bstr0([chars UTF8String]);
    int key = convert_key([event keyCode], bstr_decode_utf8(t, &t));

    if (key > -1)
        [self handleMPKey:key withMask:[self keyModifierMask:event]];

    return nil;
}

- (BOOL)handleMediaKey:(NSEvent *)event
{
    if (!_media_keys_enabled)
        return NO;

    NSInteger data1 = [event data1];
    int keycode  = (data1 & 0xFFFF0000) >> 16;
    int keyflags =  data1 & 0x0000FFFF;
    int keystate = (keyflags & 0xFF00) >> 8;

    int mpkey;
    switch (keycode) {
    case NX_KEYTYPE_PLAY:     mpkey = MP_KEY_PLAY; break;
    case NX_KEYTYPE_FAST:
    case NX_KEYTYPE_NEXT:     mpkey = MP_KEY_NEXT; break;
    case NX_KEYTYPE_REWIND:
    case NX_KEYTYPE_PREVIOUS: mpkey = MP_KEY_PREV; break;
    default:
        // not ours (volume, brightness, ...): leave it to the system
        return NO;
    }

    if (keystate == 0x0A) // key down; 0x0B is key up
        [self putKey:mpkey];
    // consume both down and up of handled keys. Without an event tap the
    // system may still route them to iTunes; this is gated behind
    // --input-media-keys anyway.
    return YES;
}

- (bool)processKeyEvent:(NSEvent *)event
{
    NSEventType type = [event type];

    if (type == NSKeyDown || type == NSKeyUp) {
        if (![[NSApp mainMenu] performKeyEquivalent:event])
            [self handleKey:event];
        return true;
    }

    if (type == NSSystemDefined &&
        [event subtype] == NX_SUBTYPE_AUX_CONTROL_BUTTONS)
        return [self handleMediaKey:event];

    return false;
}

- (void)handleFilesArray:(NSArray *)files
{
    enum mp_dnd_action action = [NSEvent modifierFlags] & NSShiftKeyMask ?
                                DND_APPEND : DND_REPLACE;

    // Build a text/uri-list style payload: newline-separated entries.
    // mp_event_drop_mime_data() splits lines and skips '#' comments; both
    // plain paths and file:// URLs are accepted by the playlist loader.
    NSMutableString *list = [NSMutableString string];
    for (NSString *p in files) {
        if ([p hasPrefix:@"file:///.file/id="])
            p = [[NSURL URLWithString:p] path];
        [list appendString:p];
        [list appendString:@"\n"];
    }

    [_input_lock lock];
    if (_inputContext)
        mp_event_drop_mime_data(_inputContext, "text/uri-list",
                                bstr0([list UTF8String]), action);
    [_input_lock unlock];
}

@end
