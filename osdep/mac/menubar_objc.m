/*
 * Full menubar for the non-Swift (ObjC) build.
 *
 * Table-driven: each menu is a static array of struct menu_item_def rows
 * (title/action/key/modifiers/target/arg/special), and one generic loop in
 * -init turns the whole table into NSMenu/NSMenuItem objects. Item names,
 * key equivalents and command strings come from the 0.41.0 Swift
 * osdep/mac/menu_bar.swift; the dispatch mechanics (queueCommand:,
 * stopMPV:, openFiles:, an argument carried on -representedObject instead
 * of a linear dictionary search) come from the pre-0.38 ObjC
 * osdep/macosx_menubar.m. See port-notes/MENUBAR-PORT.md for the full
 * item list and the reasoning behind each API-floor guard below.
 *
 * --macos-menu-shortcuts cannot be honoured here: this menubar is built by
 * init_cocoa_application() before mpv parses its command line, so key
 * equivalents are always enabled.
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

#import "osdep/mac/menubar_objc.h"
#include "osdep/mac/compat_legacy.h"
#import "osdep/mac/app_objc.h"
#include "common/common.h"
#include <string.h>
#include <stdlib.h>

enum menu_target { TGT_NONE = 0, TGT_SELF, TGT_APP };

struct menu_item_def {
    const char *title;       // NULL => separator
    const char *action;      // selector name, NULL => no action
    const char *key;         // key equivalent, "" => none
    unsigned modifiers;       // 0 => AppKit default (Command)
    enum menu_target target;
    const char *arg;         // command / URL / file for the action
    int special;              // MPMenuKey, or -1
};

struct menu_def {
    const char *title;
    const struct menu_item_def *items;
    int count;
};

// --- row-building helpers: each row of a menu table is one line. ---

// A separator.
#define SEP \
    { NULL, NULL, "", 0, TGT_NONE, NULL, -1 }
// A plain AppKit action, dispatched via the responder chain (nil target)
// unless overridden with ACTNT: Close, Undo/Redo/Cut/Copy/Paste/Select
// All, and the default Minimize/Zoom actions all work this way.
#define ACTN(title, action, key) \
    { title, action, key, 0, TGT_NONE, NULL, -1 }
// Same, with an explicit target and/or a non-default modifier mask.
#define ACTNT(title, action, key, mods, tgt) \
    { title, action, key, mods, tgt, NULL, -1 }
// An mpv command dispatched through -cmd:, target self.
#define CMD(title, key, command) \
    { title, "cmd:", key, 0, TGT_SELF, command, -1 }
// A help URL dispatched through -url:, target self.
#define WEBURL(title, url) \
    { title, "url:", "", 0, TGT_SELF, url, -1 }
// A MenuBar action with an explicit target and a representedObject
// argument (quit:, preferences:, showFile:).
#define ACTARG(title, action, key, tgt, arg) \
    { title, action, key, 0, tgt, arg, -1 }
// A VO-registered special item with no action until registerSelector:
// wires one up, hence auto-disabled: Half/Normal/Double Size.
#define SPECIAL(title, key, spec) \
    { title, NULL, key, 0, TGT_NONE, NULL, spec }
// A special item that already has a default action so it works before any
// window exists (Minimize/Zoom); registerSelector: may later replace it.
#define SPECIAL_ACT(title, action, key, spec) \
    { title, action, key, 0, TGT_NONE, NULL, spec }

static const struct menu_item_def apple_menu_items[] = {
    ACTNT("About mpv", "about:", "", 0, TGT_SELF),
    SEP,
    ACTARG("Settings...", "preferences:", ",", TGT_SELF, "mpv.conf"),
    ACTARG("Keyboard Shortcuts Config...", "preferences:", "", TGT_SELF,
           "input.conf"),
    SEP,
    // Services submenu placeholder; -init attaches the real services menu
    // by matching this title (see the "Services" check below).
    ACTN("Services", NULL, ""),
    SEP,
    ACTNT("Hide mpv", "hide:", "h", 0, TGT_APP),
    ACTNT("Hide Others", "hideOtherApplications:", "h",
          NSEventModifierFlagCommand | NSEventModifierFlagOption, TGT_APP),
    ACTNT("Show All", "unhideAllApplications:", "", 0, TGT_APP),
    SEP,
    ACTARG("Quit and Remember Position", "quit:", "", TGT_SELF,
           "quit-watch-later"),
    ACTARG("Quit mpv", "quit:", "q", TGT_SELF, "quit"),
};

static const struct menu_item_def file_menu_items[] = {
    ACTNT("Open File...", "openFile:", "o", 0, TGT_SELF),
#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1050
    ACTNT("Open URL...", "openURL:", "O", 0, TGT_SELF),
#endif
    ACTNT("Open Playlist...", "openPlaylist:", "", 0, TGT_SELF),
    SEP,
    ACTN("Close", "performClose:", "w"),
    CMD("Save Screenshot", "", "async screenshot"),
};

// All nil target / first responder: this is what makes Cmd-V work in the
// Open URL field and in any NSOpenPanel.
static const struct menu_item_def edit_menu_items[] = {
    ACTN("Undo", "undo:", "z"),
    ACTN("Redo", "redo:", "Z"),
    SEP,
    ACTN("Cut", "cut:", "x"),
    ACTN("Copy", "copy:", "c"),
    ACTN("Paste", "paste:", "v"),
    ACTN("Select All", "selectAll:", "a"),
};

static const struct menu_item_def view_menu_items[] = {
    CMD("Toggle Fullscreen", "", "cycle fullscreen"),
    CMD("Toggle Float on Top", "", "cycle ontop"),
    CMD("Toggle Visibility on All Workspaces", "", "cycle on-all-workspaces"),
    // No Touch Bar entry: HAVE_MACOS_TOUCHBAR is never set in this build.
};

static const struct menu_item_def video_menu_items[] = {
    CMD("Zoom Out", "", "add panscan -0.1"),
    CMD("Zoom In", "", "add panscan 0.1"),
    CMD("Reset Zoom", "", "set panscan 0"),
    SEP,
    CMD("Aspect Ratio 4:3", "", "set video-aspect-override \"4:3\""),
    CMD("Aspect Ratio 16:9", "", "set video-aspect-override \"16:9\""),
    CMD("Aspect Ratio 1.85:1", "", "set video-aspect-override \"1.85:1\""),
    CMD("Aspect Ratio 2.35:1", "", "set video-aspect-override \"2.35:1\""),
    CMD("Reset Aspect Ratio", "", "set video-aspect-override \"-1\""),
    SEP,
    CMD("Rotate Left", "", "cycle-values video-rotate 0 270 180 90"),
    CMD("Rotate Right", "", "cycle-values video-rotate 90 180 270 0"),
    CMD("Reset Rotation", "", "set video-rotate 0"),
    SEP,
    SPECIAL("Half Size", "0", MPM_H_SIZE),
    SPECIAL("Normal Size", "1", MPM_N_SIZE),
    SPECIAL("Double Size", "2", MPM_D_SIZE),
};

static const struct menu_item_def audio_menu_items[] = {
    CMD("Next Audio Track", "", "cycle audio"),
    CMD("Previous Audio Track", "", "cycle audio down"),
    SEP,
    CMD("Toggle Mute", "", "cycle mute"),
    SEP,
    CMD("Play Audio Later", "", "add audio-delay 0.1"),
    CMD("Play Audio Earlier", "", "add audio-delay -0.1"),
    CMD("Reset Audio Delay", "", "set audio-delay 0.0"),
};

static const struct menu_item_def subtitle_menu_items[] = {
    CMD("Next Subtitle Track", "", "cycle sub"),
    CMD("Previous Subtitle Track", "", "cycle sub down"),
    SEP,
    CMD("Toggle Force Style", "", "cycle-values sub-ass-override \"force\" \"no\""),
    SEP,
    CMD("Display Subtitles Later", "", "add sub-delay 0.1"),
    CMD("Display Subtitles Earlier", "", "add sub-delay -0.1"),
    CMD("Reset Subtitle Delay", "", "set sub-delay 0.0"),
};

static const struct menu_item_def playback_menu_items[] = {
    CMD("Toggle Pause", "", "cycle pause"),
    CMD("Increase Speed", "", "add speed 0.1"),
    CMD("Decrease Speed", "", "add speed -0.1"),
    CMD("Reset Speed", "", "set speed 1.0"),
    SEP,
    CMD("Show Playlist", "", "show-text ${playlist} 3000"),
    CMD("Show Chapters", "", "show-text ${chapter-list} 3000"),
    CMD("Show Tracks", "", "show-text ${track-list} 3000"),
    SEP,
    CMD("Next File", "", "playlist-next"),
    CMD("Previous File", "", "playlist-prev"),
    CMD("Toggle Loop File", "", "cycle-values loop-file \"inf\" \"no\""),
    CMD("Toggle Loop Playlist", "", "cycle-values loop-playlist \"inf\" \"no\""),
    CMD("Shuffle", "", "playlist-shuffle"),
    SEP,
    CMD("Next Chapter", "", "add chapter 1"),
    CMD("Previous Chapter", "", "add chapter -1"),
    SEP,
    CMD("Step Forward", "", "frame-step"),
    CMD("Step Backward", "", "frame-back-step"),
};

// Also -[NSApp setWindowsMenu:], as the compact version did.
static const struct menu_item_def window_menu_items[] = {
    SPECIAL_ACT("Minimize", "performMiniaturize:", "m", MPM_MINIMIZE),
    SPECIAL_ACT("Zoom", "performZoom:", "", MPM_ZOOM),
};

static const struct menu_item_def help_menu_items[] = {
    WEBURL("mpv Website...", "https://mpv.io"),
    WEBURL("mpv on GitHub...", "https://github.com/mpv-player/mpv"),
    SEP,
    WEBURL("Online Manual...", "https://mpv.io/manual/master/"),
    WEBURL("Online Wiki...", "https://github.com/mpv-player/mpv/wiki"),
    WEBURL("Release Notes...",
           "https://github.com/mpv-player/mpv/blob/master/RELEASE_NOTES"),
    WEBURL("Keyboard Shortcuts...",
           "https://github.com/mpv-player/mpv/blob/master/etc/input.conf"),
    SEP,
    WEBURL("Report Issue...",
           "https://github.com/mpv-player/mpv/issues/new/choose"),
    // Shown only inside the app bundle; -init skips this row by title when
    // getenv("MPVBUNDLE") is not "true" (set by setup_bundle() before the
    // menubar is created; the bundle's mpv.conf sets the matching log-file).
    ACTARG("Show log File...", "showFile:", "", TGT_SELF,
           "~/Library/Logs/mpv.log"),
};

#define MENU(title, items) { title, items, (int)MP_ARRAY_SIZE(items) }

static const struct menu_def g_menus[] = {
    MENU("mpv",      apple_menu_items),
    MENU("File",     file_menu_items),
    MENU("Edit",     edit_menu_items),
    MENU("View",     view_menu_items),
    MENU("Video",    video_menu_items),
    MENU("Audio",    audio_menu_items),
    MENU("Subtitle", subtitle_menu_items),
    MENU("Playback", playback_menu_items),
    MENU("Window",   window_menu_items),
    MENU("Help",     help_menu_items),
};

// Builds one NSMenuItem from a row and adds it to menu; returns nil for a
// separator (which is still added to menu).
static NSMenuItem *build_item(NSMenu *menu, id target_self,
                               const struct menu_item_def *def)
{
    if (!def->title) {
        [menu addItem:[NSMenuItem separatorItem]];
        return nil;
    }

    NSString *title = [NSString stringWithUTF8String:def->title];
    NSString *key = [NSString stringWithUTF8String:def->key];
    SEL action = def->action ?
        NSSelectorFromString([NSString stringWithUTF8String:def->action]) :
        nil;

    NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:title
                                                    action:action
                                             keyEquivalent:key] autorelease];

    switch (def->target) {
    case TGT_SELF: [item setTarget:target_self]; break;
    case TGT_APP:  [item setTarget:NSApp]; break;
    case TGT_NONE: default: break; // nil target: first-responder chain
    }

    if (def->modifiers)
        [item setKeyEquivalentModifierMask:def->modifiers];

    if (def->arg)
        [item setRepresentedObject:[NSString stringWithUTF8String:def->arg]];

    [menu addItem:item];
    return item;
}

@implementation MenuBar

- (id)init
{
    if (self = [super init]) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setBool:NO forKey:@"NSFullScreenMenuItemEverywhere"];
        [defaults setBool:YES forKey:@"NSDisabledDictationMenuItem"];
        [defaults setBool:YES forKey:@"NSDisabledCharacterPaletteMenuItem"];

#if MAC_OS_X_VERSION_MAX_ALLOWED >= 101200
        if ([NSWindow respondsToSelector:@selector(setAllowsAutomaticWindowTabbing:)])
            [NSWindow setAllowsAutomaticWindowTabbing:NO];
#endif

        NSMenu *main_menu =
            [[[NSMenu alloc] initWithTitle:@"MainMenu"] autorelease];
        NSMenu *services_menu =
            [[[NSMenu alloc] initWithTitle:@"Services"] autorelease];
        NSMenu *window_menu = nil;

        const char *bundle_env = getenv("MPVBUNDLE");
        BOOL in_bundle = bundle_env && strcmp(bundle_env, "true") == 0;
        // The Open URL dialog needs -[NSAlert setAccessoryView:] (10.5+);
        // a 10.5-SDK build running on 10.4 must not offer the item.
        BOOL have_alert_accessory = [NSAlert instancesRespondToSelector:
                                        @selector(setAccessoryView:)];

        for (int i = 0; i < (int)MP_ARRAY_SIZE(g_menus); i++) {
            const struct menu_def *mdef = &g_menus[i];
            NSString *menu_title = [NSString stringWithUTF8String:mdef->title];
            NSMenu *menu =
                [[[NSMenu alloc] initWithTitle:menu_title] autorelease];
            NSMenuItem *top = [main_menu addItemWithTitle:menu_title
                                                     action:nil
                                              keyEquivalent:@""];
            [main_menu setSubmenu:menu forItem:top];

            for (int j = 0; j < mdef->count; j++) {
                const struct menu_item_def *def = &mdef->items[j];

                if (def->title && !strcmp(def->title, "Show log File...") &&
                    !in_bundle)
                    continue;
                if (def->title && !strcmp(def->title, "Open URL...") &&
                    !have_alert_accessory)
                    continue;

                NSMenuItem *item = build_item(menu, self, def);
                if (!item)
                    continue; // separator

                if (!strcmp(def->title, "Services"))
                    [item setSubmenu:services_menu];

                if (def->special >= 0 && def->special < MPM_KEY_COUNT)
                    _special_items[def->special] = item;
            }

            if (!strcmp(mdef->title, "Window"))
                window_menu = menu;
        }

        [NSApp setMainMenu:main_menu];
        [NSApp setServicesMenu:services_menu];
        if (window_menu)
            [NSApp setWindowsMenu:window_menu];
    }
    return self;
}

- (void)alertWithTitle:(NSString *)title text:(NSString *)text
{
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:title];
    [alert setInformativeText:text];
    [alert addButtonWithTitle:@"Ok"];
    [alert setIcon:[(Application *)NSApp getMPVIcon]];
    [alert runModal];
}

- (void)about:(id)sender
{
    NSMutableDictionary *options = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        @"mpv", @"ApplicationName",
        [NSString stringWithUTF8String:mpv_copyright], @"Copyright",
        [NSString stringWithUTF8String:mpv_version], @"ApplicationVersion",
        nil];
    // Added separately: a nil object would terminate the varargs list above
    // and silently drop everything after it.
    NSImage *icon = [(Application *)NSApp getMPVIcon];
    if (icon)
        [options setObject:icon forKey:@"ApplicationIcon"];
    [NSApp orderFrontStandardAboutPanelWithOptions:options];
}

- (void)preferences:(id)sender
{
    NSString *file = [sender representedObject];
    NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    // 0.41 order: ~/.config/mpv/ before ~/.mpv/.
    NSArray *configPaths = [NSArray arrayWithObjects:
        [NSHomeDirectory() stringByAppendingString:@"/.config/mpv/"],
        [NSHomeDirectory() stringByAppendingString:@"/.mpv/"],
        nil];

    for (NSUInteger i = 0; i < [configPaths count]; i++) {
        NSString *path = [configPaths objectAtIndex:i];
        NSString *fileP = [path stringByAppendingString:file];
        if ([fileManager fileExistsAtPath:fileP]) {
            if ([workspace openFile:fileP])
                return;
            [workspace openFile:path];
            [self alertWithTitle:@"No Application found to open your config file."
                             text:[NSString stringWithFormat:
                                 @"Please open the %@ file with your preferred "
                                  "text editor in the now open folder to edit "
                                  "your config.", file]];
            return;
        }
        if ([workspace openFile:path]) {
            [self alertWithTitle:@"No config file found."
                             text:[NSString stringWithFormat:
                                 @"Please create a %@ file with your preferred "
                                  "text editor in the now open folder.", file]];
            return;
        }
    }

    [self alertWithTitle:@"No config path or file found."
                     text:[NSString stringWithFormat:
                         @"Please create the following path ~/.config/mpv/ "
                          "and a %@ file within with your preferred text "
                          "editor.", file]];
}

- (void)quit:(id)sender
{
    NSString *cmd = [sender representedObject];
    [(Application *)NSApp stopMPV:(char *)[cmd UTF8String]];
}

- (void)openFile:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setCanChooseDirectories:YES];
    [panel setAllowsMultipleSelection:YES];
    // NSModalResponseOK/-filenames: deprecated but present and correct on
    // every SDK this branch targets (compat_legacy.h maps the name to the
    // legacy NSOKButton constant on pre-10.12 SDKs).
    if ([panel runModal] == NSModalResponseOK)
        [(Application *)NSApp openFiles:[panel filenames]];
}

- (void)openPlaylist:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    if ([panel runModal] == NSModalResponseOK) {
        NSString *file = [[panel filenames] objectAtIndex:0];
        NSString *cmd = [NSString stringWithFormat:@"loadlist \"%@\"", file];
        [(Application *)NSApp queueCommand:(char *)[cmd UTF8String]];
    }
}

#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1050
- (void)openURL:(id)sender
{
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:@"Open URL"];
    [alert addButtonWithTitle:@"Ok"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert setIcon:[(Application *)NSApp getMPVIcon]];

    NSTextField *input =
        [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)]
            autorelease];
    [[input cell] setPlaceholderString:@"URL"];
    [alert setAccessoryView:input];
    [[alert window] setInitialFirstResponder:input];

    if ([alert runModal] == NSAlertFirstButtonReturn &&
        [[input stringValue] length] > 0) {
        NSArray *files = [NSArray arrayWithObjects:[input stringValue], nil];
        [(Application *)NSApp openFiles:files];
    }
}
#endif

- (void)cmd:(id)sender
{
    NSString *cmd = [sender representedObject];
    [(Application *)NSApp queueCommand:(char *)[cmd UTF8String]];
}

- (void)url:(id)sender
{
    NSString *url = [sender representedObject];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:url]];
}

- (void)showFile:(id)sender
{
    NSString *file =
        [[sender representedObject] stringByExpandingTildeInPath];
    NSFileManager *fileManager = [NSFileManager defaultManager];

    if ([fileManager fileExistsAtPath:file]) {
        NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
        // -activateFileViewerSelectingURLs: is 10.6+ (undeclared in older
        // SDKs); -selectFile:inFileViewerRootedAtPath: goes back to 10.0.
#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1060
        if ([workspace respondsToSelector:
                @selector(activateFileViewerSelectingURLs:)]) {
            NSURL *url = [NSURL fileURLWithPath:file];
            [workspace activateFileViewerSelectingURLs:
                [NSArray arrayWithObjects:url, nil]];
            return;
        }
#endif
        [workspace selectFile:file inFileViewerRootedAtPath:@""];
        return;
    }

    [self alertWithTitle:@"No log File found."
                     text:@"You deactivated logging for the Bundle."];
}

- (void)registerSelector:(SEL)action forKey:(MPMenuKey)key
{
    if ((int)key >= 0 && key < MPM_KEY_COUNT && _special_items[key])
        [_special_items[key] setAction:action];
}

@end
