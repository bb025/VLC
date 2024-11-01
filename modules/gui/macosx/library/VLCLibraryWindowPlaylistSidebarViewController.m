/*****************************************************************************
 * VLCLibraryWindowPlaylistSidebarViewController.m: MacOS X interface module
 *****************************************************************************
 * Copyright (C) 2024 VLC authors and VideoLAN
 *
 * Authors: Claudio Cambra <developer@claudiocambra.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/

#import "VLCLibraryWindowPlaylistSidebarViewController.h"

#import "extensions/NSColor+VLCAdditions.h"
#import "extensions/NSFont+VLCAdditions.h"
#import "extensions/NSImage+VLCAdditions.h"
#import "extensions/NSString+Helpers.h"
#import "extensions/NSWindow+VLCAdditions.h"
#import "library/VLCLibraryUIUnits.h"
#import "library/VLCLibraryWindow.h"
#import "main/VLCMain.h"
#import "playlist/VLCPlaylistController.h"
#import "playlist/VLCPlaylistDataSource.h"
#import "playlist/VLCPlaylistSortingMenuController.h"
#import "views/VLCDragDropView.h"
#import "views/VLCRoundedCornerTextField.h"
#import "windows/VLCOpenWindowController.h"

@implementation VLCLibraryWindowPlaylistSidebarViewController

@synthesize counterLabel = _counterLabel;

- (instancetype)initWithLibraryWindow:(VLCLibraryWindow *)libraryWindow
{
    return [super initWithLibraryWindow:libraryWindow
                                nibName:@"VLCLibraryWindowPlaylistView"];
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.dragDropView.dropTarget = self.libraryWindow;

    _playlistController = VLCMain.sharedInstance.playlistController;
    _dataSource = [[VLCPlaylistDataSource alloc] init];
    self.dataSource.playlistController = self.playlistController;
    self.dataSource.tableView = self.tableView;
    self.dataSource.dragDropView = self.dragDropView;
    self.dataSource.counterTextField = self.counterLabel;
    [self.dataSource prepareForUse];
    self.playlistController.playlistDataSource = self.dataSource;

    self.tableView.dataSource = self.dataSource;
    self.tableView.delegate = self.dataSource;
    self.tableView.rowHeight = VLCLibraryUIUnits.mediumTableViewRowHeight;
    [self.tableView reloadData];

    self.openMediaButton.title = _NS("Open media...");
    self.dragDropImageBackgroundBox.fillColor = NSColor.VLClibrarySeparatorLightColor;

    [self repeatStateUpdated:nil];
    [self shuffleStateUpdated:nil];

    NSNotificationCenter * const notificationCenter = NSNotificationCenter.defaultCenter;
    [notificationCenter addObserver:self
                           selector:@selector(shuffleStateUpdated:)
                               name:VLCPlaybackOrderChanged
                             object:nil];
    [notificationCenter addObserver:self
                           selector:@selector(repeatStateUpdated:)
                               name:VLCPlaybackRepeatChanged
                             object:nil];
}

- (NSString *)title
{
    return _NS("Playlist");
}

- (BOOL)supportsItemCount
{
    return YES;
}

- (void)setCounterLabel:(NSTextField *)counterLabel
{
    _counterLabel = counterLabel;
    self.dataSource.counterTextField = counterLabel;
}

#pragma mark - appearance setters

- (void)updateColorsBasedOnAppearance:(NSAppearance *)appearance
{
    [super updateColorsBasedOnAppearance:appearance];

    BOOL isDark = NO;
    if (@available(macOS 10.14, *)) {
        isDark = [appearance.name isEqualToString:NSAppearanceNameDarkAqua] || 
                 [appearance.name isEqualToString:NSAppearanceNameVibrantDark];
    }

    // If we try to pull the view's effectiveAppearance we are going to get the previous 
    // appearance's name despite responding to the effectiveAppearance change (???) so it is a
    // better idea to pull from the general system theme preference, which is always up-to-date
    if (isDark) {
        self.bottomButtonsSeparator.borderColor = NSColor.VLClibrarySeparatorDarkColor;
        self.dragDropImageBackgroundBox.hidden = NO;
    } else {
        self.bottomButtonsSeparator.borderColor = NSColor.VLClibrarySeparatorLightColor;
        self.dragDropImageBackgroundBox.hidden = YES;
    }
}

#pragma mark - table view interaction

- (IBAction)tableDoubleClickAction:(id)sender
{
    const NSInteger selectedRow = self.tableView.selectedRow;
    if (selectedRow == -1) {
        return;
    }
    [VLCMain.sharedInstance.playlistController playItemAtIndex:selectedRow];
}

#pragma mark - open media handling

- (IBAction)openMedia:(id)sender
{
    [VLCMain.sharedInstance.open openFileGeneric];
}

#pragma mark - playmode state display and interaction

- (IBAction)shuffleAction:(id)sender
{
    if (_playlistController.playbackOrder == VLC_PLAYLIST_PLAYBACK_ORDER_NORMAL) {
        _playlistController.playbackOrder = VLC_PLAYLIST_PLAYBACK_ORDER_RANDOM;
    } else {
        _playlistController.playbackOrder = VLC_PLAYLIST_PLAYBACK_ORDER_NORMAL;
    }
}

- (void)shuffleStateUpdated:(NSNotification *)aNotification
{
    if (@available(macOS 11.0, *)) {
        self.shuffleButton.image = [NSImage imageWithSystemSymbolName:@"shuffle"
                                             accessibilityDescription:@"Shuffle"];
        self.shuffleButton.contentTintColor =
            self.playlistController.playbackOrder == VLC_PLAYLIST_PLAYBACK_ORDER_NORMAL ?
                nil : NSColor.VLCAccentColor;
    } else {
        self.shuffleButton.image =
            self.playlistController.playbackOrder == VLC_PLAYLIST_PLAYBACK_ORDER_NORMAL ?
                [NSImage imageNamed:@"shuffleOff"] :
                [[NSImage imageNamed:@"shuffleOn"] imageTintedWithColor:NSColor.VLCAccentColor];
    }
}

- (IBAction)repeatAction:(id)sender
{
    const enum vlc_playlist_playback_repeat repeatState = self.playlistController.playbackRepeat;
    switch (repeatState) {
        case VLC_PLAYLIST_PLAYBACK_REPEAT_ALL:
            self.playlistController.playbackRepeat = VLC_PLAYLIST_PLAYBACK_REPEAT_NONE;
            break;
        case VLC_PLAYLIST_PLAYBACK_REPEAT_CURRENT:
            self.playlistController.playbackRepeat = VLC_PLAYLIST_PLAYBACK_REPEAT_ALL;
            break;
        default:
            self.playlistController.playbackRepeat = VLC_PLAYLIST_PLAYBACK_REPEAT_CURRENT;
            break;
    }
}

- (void)repeatStateUpdated:(NSNotification *)aNotification
{
    const enum vlc_playlist_playback_repeat repeatState = self.playlistController.playbackRepeat;

    if (@available(macOS 11.0, *)) {
        switch (repeatState) {
            case VLC_PLAYLIST_PLAYBACK_REPEAT_CURRENT:
                self.repeatButton.image = [NSImage imageWithSystemSymbolName:@"repeat.1"
                                                    accessibilityDescription:@"Repeat current"];
                self.repeatButton.contentTintColor = NSColor.VLCAccentColor;
                break;
            case VLC_PLAYLIST_PLAYBACK_REPEAT_ALL:
                self.repeatButton.image = [NSImage imageWithSystemSymbolName:@"repeat"
                                                    accessibilityDescription:@"Repeat"];
                self.repeatButton.contentTintColor = NSColor.VLCAccentColor;
                break;
            default:
                self.repeatButton.image = [NSImage imageWithSystemSymbolName:@"repeat"
                                                    accessibilityDescription:@"Repeat"];
                self.repeatButton.contentTintColor = nil;
                break;
        }
    } else {
        switch (repeatState) {
            case VLC_PLAYLIST_PLAYBACK_REPEAT_ALL:
                self.repeatButton.image =
                    [[NSImage imageNamed:@"repeatAll"] imageTintedWithColor:NSColor.VLCAccentColor];
                break;
            case VLC_PLAYLIST_PLAYBACK_REPEAT_CURRENT:
                self.repeatButton.image =
                    [[NSImage imageNamed:@"repeatOne"] imageTintedWithColor:NSColor.VLCAccentColor];
                break;
            default:
                self.repeatButton.image = [NSImage imageNamed:@"repeatOff"];
                break;
        }
    }
}

- (IBAction)sortPlaylist:(id)sender
{
    if (!self.sortingMenuController) {
        _sortingMenuController = [[VLCPlaylistSortingMenuController alloc] init];
    }
    [NSMenu popUpContextMenu:self.sortingMenuController.playlistSortingMenu
                   withEvent:NSApp.currentEvent
                     forView:sender];
}

- (IBAction)clearPlaylist:(id)sender
{
    [self.playlistController clearPlaylist];
}

@end
