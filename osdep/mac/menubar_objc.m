/*
 * Compact menubar for the non-Swift (ObjC) build.
 *
 * Deliberately minimal: app menu (About/Hide/Quit), File > Open, and a
 * standard Window menu. The full pre-0.38 macosx_menubar.m (831 lines of
 * playback/video/audio menus wired via queueCommand:) can be ported on top
 * of this without touching any other file.
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
#import "osdep/mac/app_objc.h"

@implementation MenuBar

static NSMenuItem *new_menu_item(NSMenu *parent, NSString *title, SEL action,
                                 NSString *key)
{
    NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:title
                                                   action:action
                                            keyEquivalent:key] autorelease];
    [parent addItem:item];
    return item;
}

static NSMenu *new_menu(NSMenu *main_menu, NSString *title)
{
    NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:title
                                                   action:nil
                                            keyEquivalent:@""] autorelease];
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:title] autorelease];
    [item setSubmenu:menu];
    [main_menu addItem:item];
    return menu;
}

- (id)init
{
    if (self = [super init]) {
        NSMenu *main_menu =
            [[[NSMenu alloc] initWithTitle:@"MainMenu"] autorelease];
        [NSApp setMainMenu:main_menu];

        // application menu (first submenu becomes the app menu)
        NSMenu *app_menu = new_menu(main_menu, @"mpv");
        new_menu_item(app_menu, @"About mpv",
                      @selector(orderFrontStandardAboutPanel:), @"");
        [app_menu addItem:[NSMenuItem separatorItem]];
        new_menu_item(app_menu, @"Hide mpv", @selector(hide:), @"h");
        new_menu_item(app_menu, @"Hide Others",
                      @selector(hideOtherApplications:), @"");
        [app_menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *quit = new_menu_item(app_menu, @"Quit mpv",
                                         @selector(quit:), @"q");
        [quit setTarget:self];

        NSMenu *file_menu = new_menu(main_menu, @"File");
        NSMenuItem *open = new_menu_item(file_menu, @"Open File…",
                                         @selector(openFile:), @"o");
        [open setTarget:self];
        new_menu_item(file_menu, @"Close", @selector(performClose:), @"w");

        NSMenu *window_menu = new_menu(main_menu, @"Window");
        new_menu_item(window_menu, @"Minimize",
                      @selector(performMiniaturize:), @"m");
        new_menu_item(window_menu, @"Zoom", @selector(performZoom:), @"");
        [NSApp setWindowsMenu:window_menu];
    }
    return self;
}

- (void)quit:(NSMenuItem *)menuItem
{
    [(Application *)NSApp stopMPV:"quit"];
}

- (void)openFile:(NSMenuItem *)menuItem
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setCanChooseDirectories:YES];
    [panel setAllowsMultipleSelection:YES];
    // NSOKButton/-filenames: deprecated but present and correct on 10.5+
    if ([panel runModal] == NSOKButton)
        [(Application *)NSApp openFiles:[panel filenames]];
}

- (void)registerSelector:(SEL)action forKey:(MPMenuKey)key
{
    if ((int)key >= 0 && key < MPM_KEY_COUNT)
        _registered_sel[key] = action;
}

@end
