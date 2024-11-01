/*****************************************************************************
 * VLCLibraryWindow.m: MacOS X interface module
 *****************************************************************************
 * Copyright (C) 2019 VLC authors and VideoLAN
 *
 * Authors: Felix Paul Kühne <fkuehne # videolan -dot- org>
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

#import "VLCLibraryWindow.h"

#import "VLCLibraryDataTypes.h"

#import "extensions/NSColor+VLCAdditions.h"
#import "extensions/NSImage+VLCAdditions.h"
#import "extensions/NSFont+VLCAdditions.h"
#import "extensions/NSString+Helpers.h"
#import "extensions/NSView+VLCAdditions.h"
#import "extensions/NSWindow+VLCAdditions.h"

#import "main/VLCMain.h"
#import "menus/VLCMainMenu.h"

#import "playlist/VLCPlayerController.h"
#import "playlist/VLCPlaylistController.h"

#import "library/VLCInputItem.h"
#import "library/VLCLibraryController.h"
#import "library/VLCLibraryCollectionViewItem.h"
#import "library/VLCLibraryCollectionViewSupplementaryElementView.h"
#import "library/VLCLibraryModel.h"
#import "library/VLCLibraryNavigationStack.h"
#import "library/VLCLibrarySegment.h"
#import "library/VLCLibrarySortingMenuController.h"
#import "library/VLCLibraryUIUnits.h"
#import "library/VLCLibraryWindowChaptersSidebarViewController.h"
#import "library/VLCLibraryWindowNavigationSidebarViewController.h"
#import "library/VLCLibraryWindowPersistentPreferences.h"
#import "library/VLCLibraryWindowSidebarRootViewController.h"
#import "library/VLCLibraryWindowSplitViewController.h"
#import "library/VLCLibraryWindowToolbarDelegate.h"

#import "library/groups-library/VLCLibraryGroupsViewController.h"

#import "library/home-library/VLCLibraryHomeViewController.h"

#import "library/video-library/VLCLibraryVideoDataSource.h"
#import "library/video-library/VLCLibraryVideoViewController.h"

#import "library/audio-library/VLCLibraryAlbumTableCellView.h"
#import "library/audio-library/VLCLibraryAudioViewController.h"
#import "library/audio-library/VLCLibraryAudioDataSource.h"

#import "library/playlist-library/VLCLibraryPlaylistViewController.h"

#import "media-source/VLCMediaSourceBaseDataSource.h"
#import "media-source/VLCLibraryMediaSourceViewController.h"

#import "views/VLCBottomBarView.h"
#import "views/VLCCustomWindowButton.h"
#import "views/VLCDragDropView.h"
#import "views/VLCLoadingOverlayView.h"
#import "views/VLCNoResultsLabel.h"
#import "views/VLCRoundedCornerTextField.h"
#import "views/VLCTrackingView.h"

#import "windows/controlsbar/VLCMainWindowControlsBar.h"

#import "windows/video/VLCVoutView.h"
#import "windows/video/VLCVideoOutputProvider.h"
#import "windows/video/VLCMainVideoViewController.h"

#import "windows/VLCDetachedAudioWindow.h"
#import "windows/VLCOpenWindowController.h"
#import "windows/VLCOpenInputMetadata.h"

#import <vlc_common.h>
#import <vlc_configuration.h>
#import <vlc_media_library.h>
#import <vlc_url.h>

const CGFloat VLCLibraryWindowMinimalWidth = 604.;
const CGFloat VLCLibraryWindowMinimalHeight = 307.;
const NSUserInterfaceItemIdentifier VLCLibraryWindowIdentifier = @"VLCLibraryWindow";

@interface VLCLibraryWindow ()
{
    NSInteger _currentSelectedViewModeSegment;
    VLCVideoWindowCommon *_temporaryAudioDecorativeWindow;
}

@property NSTimer *searchInputTimer;

@end

static int ShowFullscreenController(vlc_object_t *p_this, const char *psz_variable,
                                    vlc_value_t old_val, vlc_value_t new_val, void *param)
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:VLCVideoWindowShouldShowFullscreenController
                                                                object:nil];
        });

        return VLC_SUCCESS;
    }
}

static int ShowController(vlc_object_t *p_this, const char *psz_variable,
                          vlc_value_t old_val, vlc_value_t new_val, void *param)
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:VLCWindowShouldShowController
                                                                object:nil];
        });

        return VLC_SUCCESS;
    }
}

static void addShadow(NSImageView *__unsafe_unretained imageView)
{
    NSShadow *buttonShadow = [[NSShadow alloc] init];

    buttonShadow.shadowBlurRadius = 15.0f;
    buttonShadow.shadowOffset = CGSizeMake(0.0f, -5.0f);
    buttonShadow.shadowColor = [NSColor blackColor];

    imageView.wantsLayer = YES;
    imageView.shadow = buttonShadow;
}

@implementation VLCLibraryWindow

- (void)awakeFromNib
{
    [super awakeFromNib];
    self.identifier = VLCLibraryWindowIdentifier;
    self.minSize = NSMakeSize(VLCLibraryWindowMinimalWidth, VLCLibraryWindowMinimalHeight);

    if(@available(macOS 10.12, *)) {
        self.tabbingMode = NSWindowTabbingModeDisallowed;
    }

    VLCMain *mainInstance = VLCMain.sharedInstance;
    _playlistController = [mainInstance playlistController];

    libvlc_int_t *libvlc = vlc_object_instance(getIntf());
    var_AddCallback(libvlc, "intf-toggle-fscontrol", ShowFullscreenController, (__bridge void *)self);
    var_AddCallback(libvlc, "intf-show", ShowController, (__bridge void *)self);

    _libraryTargetView = [[NSView alloc] init];

    self.navigationStack = [[VLCLibraryNavigationStack alloc] init];
    self.navigationStack.delegate = self;

    self.videoViewController.view.frame = self.mainSplitView.frame;
    self.videoViewController.view.hidden = YES;
    self.videoViewController.displayLibraryControls = YES;
    [self hideControlsBarImmediately];

    NSNotificationCenter *notificationCenter = NSNotificationCenter.defaultCenter;
    [notificationCenter addObserver:self
                           selector:@selector(shouldShowController:)
                               name:VLCWindowShouldShowController
                             object:nil];
    [notificationCenter addObserver:self
                           selector:@selector(playerStateChanged:)
                               name:VLCPlayerCurrentMediaItemChanged
                             object:nil];
    [notificationCenter addObserver:self
                           selector:@selector(playerStateChanged:)
                               name:VLCPlayerStateChanged
                             object:nil];
    [notificationCenter addObserver:self
                           selector:@selector(playerTrackSelectionChanged:)
                               name:VLCPlayerTrackSelectionChanged
                             object:nil];

    _libraryMediaSourceViewController = [[VLCLibraryMediaSourceViewController alloc] initWithLibraryWindow:self];

    [self setViewForSelectedSegment];
    [self setupLoadingOverlayView];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    libvlc_int_t *libvlc = vlc_object_instance(getIntf());
    var_DelCallback(libvlc, "intf-toggle-fscontrol", ShowFullscreenController, (__bridge void *)self);
    var_DelCallback(libvlc, "intf-show", ShowController, (__bridge void *)self);
}

- (void)encodeRestorableStateWithCoder:(NSCoder *)coder
{
    [super encodeRestorableStateWithCoder:coder];
    [coder encodeInteger:_librarySegmentType forKey:@"macosx-library-selected-segment"];
}

- (void)setupLoadingOverlayView
{
    _loadingOverlayView = [[VLCLoadingOverlayView alloc] init];
    self.loadingOverlayView.translatesAutoresizingMaskIntoConstraints = NO;
    _loadingOverlayViewConstraints = @[
        [NSLayoutConstraint constraintWithItem:self.loadingOverlayView
                                     attribute:NSLayoutAttributeTop
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:self.libraryTargetView
                                     attribute:NSLayoutAttributeTop
                                    multiplier:1
                                      constant:0],
        [NSLayoutConstraint constraintWithItem:self.loadingOverlayView
                                     attribute:NSLayoutAttributeRight
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:self.libraryTargetView
                                     attribute:NSLayoutAttributeRight
                                    multiplier:1
                                      constant:0],
        [NSLayoutConstraint constraintWithItem:self.loadingOverlayView
                                     attribute:NSLayoutAttributeBottom
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:self.libraryTargetView
                                     attribute:NSLayoutAttributeBottom
                                    multiplier:1
                                      constant:0],
        [NSLayoutConstraint constraintWithItem:self.loadingOverlayView
                                     attribute:NSLayoutAttributeLeft
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:self.libraryTargetView
                                     attribute:NSLayoutAttributeLeft
                                    multiplier:1
                                      constant:0]
    ];
}

#pragma mark - misc. user interactions

- (void)updateGridVsListViewModeSegmentedControl
{
    VLCLibraryWindowPersistentPreferences * const preferences = VLCLibraryWindowPersistentPreferences.sharedInstance;

    switch (_librarySegmentType) {
    case VLCLibraryHomeSegment:
        _currentSelectedViewModeSegment = preferences.homeLibraryViewMode;
    case VLCLibraryVideoSegment:
        _currentSelectedViewModeSegment = preferences.videoLibraryViewMode;
        break;
    case VLCLibraryShowsVideoSubSegment:
        _currentSelectedViewModeSegment = preferences.showsLibraryViewMode;
        break;
    case VLCLibraryMusicSegment:
    case VLCLibraryArtistsMusicSubSegment:
        _currentSelectedViewModeSegment = preferences.artistLibraryViewMode;
        break;
    case VLCLibraryGenresMusicSubSegment:
        _currentSelectedViewModeSegment = preferences.genreLibraryViewMode;
        break;
    case VLCLibraryAlbumsMusicSubSegment:
        _currentSelectedViewModeSegment = preferences.albumLibraryViewMode;
        break;
    case VLCLibrarySongsMusicSubSegment:
        _currentSelectedViewModeSegment = preferences.songsLibraryViewMode;
        break;
    case VLCLibraryPlaylistsSegment:
        _currentSelectedViewModeSegment = preferences.playlistLibraryViewMode;
        break;
    case VLCLibraryPlaylistsMusicOnlyPlaylistsSubSegment:
        _currentSelectedViewModeSegment = preferences.musicOnlyPlaylistLibraryViewMode;
        break;
    case VLCLibraryPlaylistsVideoOnlyPlaylistsSubSegment:
        _currentSelectedViewModeSegment = preferences.videoOnlyPlaylistLibraryViewMode;
        break;
    case VLCLibraryBrowseSegment:
        _currentSelectedViewModeSegment = preferences.browseLibraryViewMode;
        break;
    case VLCLibraryStreamsSegment:
        _currentSelectedViewModeSegment = preferences.streamLibraryViewMode;
        break;
    case VLCLibraryGroupsSegment:
    case VLCLibraryGroupsGroupSubSegment:
        _currentSelectedViewModeSegment = preferences.groupsLibraryViewMode;
        break;
    default:
        break;
    }

    _gridVsListSegmentedControl.selectedSegment = _currentSelectedViewModeSegment;
}

- (void)setViewForSelectedSegment
{
    switch (_librarySegmentType) {
    case VLCLibraryHomeSegment:
        [self showHomeLibrary];
        break;
    case VLCLibraryVideoSegment:
        [self showVideoLibrary];
        break;
    case VLCLibraryShowsVideoSubSegment:
        [self showShowLibrary];
        break;
    case VLCLibraryMusicSegment:
    case VLCLibraryArtistsMusicSubSegment:
    case VLCLibraryAlbumsMusicSubSegment:
    case VLCLibrarySongsMusicSubSegment:
    case VLCLibraryGenresMusicSubSegment:
        [self showAudioLibrary];
        break;
    case VLCLibraryPlaylistsSegment:
        [self showPlaylistLibrary:VLC_ML_PLAYLIST_TYPE_ALL];
        break;
    case VLCLibraryPlaylistsMusicOnlyPlaylistsSubSegment:
        [self showPlaylistLibrary:VLC_ML_PLAYLIST_TYPE_AUDIO_ONLY];
        break;
    case VLCLibraryPlaylistsVideoOnlyPlaylistsSubSegment:
        [self showPlaylistLibrary:VLC_ML_PLAYLIST_TYPE_VIDEO_ONLY];
        break;
    case VLCLibraryBrowseSegment:
    case VLCLibraryBrowseBookmarkedLocationSubSegment:
    case VLCLibraryStreamsSegment:
        [self showMediaSourceLibrary];
        break;
    case VLCLibraryGroupsSegment:
    case VLCLibraryGroupsGroupSubSegment:
        [self showGroupsLibrary];
    default:
        break;
    }

    [self invalidateRestorableState];
}

- (void)setLibrarySegmentType:(NSInteger)segmentType
{
    if (segmentType == _librarySegmentType) {
        return;
    }

    _librarySegmentType = segmentType;
    [self setViewForSelectedSegment];
    [self updateGridVsListViewModeSegmentedControl];
}

- (IBAction)gridVsListSegmentedControlAction:(id)sender
{
    if (_gridVsListSegmentedControl.selectedSegment == _currentSelectedViewModeSegment) {
        return;
    }

    _currentSelectedViewModeSegment = _gridVsListSegmentedControl.selectedSegment;

    VLCLibraryWindowPersistentPreferences * const preferences = VLCLibraryWindowPersistentPreferences.sharedInstance;

    switch (_librarySegmentType) {
    case VLCLibraryHomeSegment:
        preferences.homeLibraryViewMode = _currentSelectedViewModeSegment;
        break;
    case VLCLibraryVideoSegment:
        preferences.videoLibraryViewMode = _currentSelectedViewModeSegment;
        break;
    case VLCLibraryShowsVideoSubSegment:
        preferences.showsLibraryViewMode = _currentSelectedViewModeSegment;
        break;
    case VLCLibraryMusicSegment:
    case VLCLibraryArtistsMusicSubSegment:
        preferences.artistLibraryViewMode = _currentSelectedViewModeSegment;
        break;
    case VLCLibraryGenresMusicSubSegment:
        preferences.genreLibraryViewMode = _currentSelectedViewModeSegment;
        break;
    case VLCLibraryAlbumsMusicSubSegment:
        preferences.albumLibraryViewMode = _currentSelectedViewModeSegment;
        break;
    case VLCLibrarySongsMusicSubSegment:
        preferences.songsLibraryViewMode = _currentSelectedViewModeSegment;
        break;
    case VLCLibraryPlaylistsSegment:
        preferences.playlistLibraryViewMode = _currentSelectedViewModeSegment;
        break;
    case VLCLibraryPlaylistsMusicOnlyPlaylistsSubSegment:
        preferences.musicOnlyPlaylistLibraryViewMode = _currentSelectedViewModeSegment;
        break;
    case VLCLibraryPlaylistsVideoOnlyPlaylistsSubSegment:
        preferences.videoOnlyPlaylistLibraryViewMode = _currentSelectedViewModeSegment;
        break;
    case VLCLibraryBrowseSegment:
    case VLCLibraryBrowseBookmarkedLocationSubSegment:
        preferences.browseLibraryViewMode = _currentSelectedViewModeSegment;
        break;
    case VLCLibraryStreamsSegment:
        preferences.streamLibraryViewMode = _currentSelectedViewModeSegment;
        break;
    case VLCLibraryGroupsSegment:
    case VLCLibraryGroupsGroupSubSegment:
        preferences.groupsLibraryViewMode = _currentSelectedViewModeSegment;
        break;
    default:
        break;
    }

    [self setViewForSelectedSegment];
}

- (void)showHomeLibrary
{
    // Only collection view mode
    [self.toolbarDelegate layoutForSegment:VLCLibraryHomeSegment];
    VLCLibraryHomeViewController * const lvc =
        [[VLCLibraryHomeViewController alloc] initWithLibraryWindow:self];
    [lvc presentHomeView];
    _librarySegmentViewController = lvc;
}

- (void)showVideoLibrary
{
    [self.toolbarDelegate layoutForSegment:VLCLibraryVideoSegment];
    VLCLibraryVideoViewController * const lvc =
        [[VLCLibraryVideoViewController alloc] initWithLibraryWindow:self];
    [lvc presentVideoView];
    _librarySegmentViewController = lvc;
}

- (void)showShowLibrary
{
    [self.toolbarDelegate layoutForSegment:VLCLibraryShowsVideoSubSegment];
    VLCLibraryVideoViewController * const lvc =
        [[VLCLibraryVideoViewController alloc] initWithLibraryWindow:self];
    [lvc presentShowsView];
    _librarySegmentViewController = lvc;
}

- (void)showAudioLibrary
{
    [self.toolbarDelegate layoutForSegment:VLCLibraryMusicSegment];
    VLCLibraryAudioViewController * const lvc =
        [[VLCLibraryAudioViewController alloc] initWithLibraryWindow:self];
    [lvc presentAudioView];
    _librarySegmentViewController = lvc;
}

- (void)showPlaylistLibrary:(enum vlc_ml_playlist_type_t)playlistType
{
    if (playlistType == VLC_ML_PLAYLIST_TYPE_AUDIO_ONLY) {
        [self.toolbarDelegate layoutForSegment:VLCLibraryPlaylistsMusicOnlyPlaylistsSubSegment];
    } else if (playlistType == VLC_ML_PLAYLIST_TYPE_VIDEO_ONLY) {
        [self.toolbarDelegate layoutForSegment:VLCLibraryPlaylistsVideoOnlyPlaylistsSubSegment];
    } else {
        [self.toolbarDelegate layoutForSegment:VLCLibraryPlaylistsSegment];
    }
    VLCLibraryPlaylistViewController * const lvc =
        [[VLCLibraryPlaylistViewController alloc] initWithLibraryWindow:self];
    [lvc presentPlaylistsViewForPlaylistType:playlistType];
    _librarySegmentViewController = lvc;
}

- (void)showMediaSourceLibrary
{
    [self.navigationStack clear];

    const VLCLibrarySegmentType segmentType = self.librarySegmentType;
    [self.toolbarDelegate layoutForSegment:segmentType];

    if (segmentType == VLCLibraryBrowseSegment) {
        [self.libraryMediaSourceViewController presentBrowseView];
    } else if (segmentType == VLCLibraryStreamsSegment) {
        [self.libraryMediaSourceViewController presentStreamsView];
    }
}

- (void)showGroupsLibrary
{
    [self.toolbarDelegate layoutForSegment:VLCLibraryGroupsSegment];
    VLCLibraryGroupsViewController * const lvc =
        [[VLCLibraryGroupsViewController alloc] initWithLibraryWindow:self];
    [lvc presentGroupsView];
    _librarySegmentViewController = lvc;
}

- (void)displayLibraryView:(NSView *)view
{
    view.translatesAutoresizingMaskIntoConstraints = NO;
    if ([self.libraryTargetView.subviews containsObject:self.loadingOverlayView]) {
        self.libraryTargetView.subviews = @[view, self.loadingOverlayView];
    } else {
        self.libraryTargetView.subviews = @[view];
    }

    [NSLayoutConstraint activateConstraints:@[
        [view.topAnchor constraintEqualToAnchor:self.libraryTargetView.topAnchor],
        [view.bottomAnchor constraintEqualToAnchor:self.libraryTargetView.bottomAnchor],
        [view.leftAnchor constraintEqualToAnchor:self.libraryTargetView.leftAnchor],
        [view.rightAnchor constraintEqualToAnchor:self.libraryTargetView.rightAnchor]
    ]];
}

- (void)displayLibraryPlaceholderViewWithImage:(NSImage *)image
                              usingConstraints:(NSArray<NSLayoutConstraint *> *)constraints
                             displayingMessage:(NSString *)message
{
    for (NSLayoutConstraint * const constraint in self.placeholderImageViewConstraints) {
        constraint.active = NO;
    }
    _placeholderImageViewConstraints = constraints;
    for (NSLayoutConstraint * const constraint in constraints) {
        constraint.active = YES;
    }

    [self displayLibraryView:self.emptyLibraryView];
    self.placeholderImageView.image = image;
    self.placeholderLabel.stringValue = message;
}

- (void)displayNoResultsMessage
{
    if (self.noResultsLabel == nil) {
        _noResultsLabel = [[VLCNoResultsLabel alloc] init];
        _noResultsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    }
    
    if ([self.libraryTargetView.subviews containsObject:self.loadingOverlayView]) {
        self.libraryTargetView.subviews = @[self.noResultsLabel, self.loadingOverlayView];
    } else {
        self.libraryTargetView.subviews = @[_noResultsLabel];
    }

    [NSLayoutConstraint activateConstraints:@[
        [self.noResultsLabel.centerXAnchor constraintEqualToAnchor:self.libraryTargetView.centerXAnchor],
        [self.noResultsLabel.centerYAnchor constraintEqualToAnchor:self.libraryTargetView.centerYAnchor]
    ]];
}

- (void)presentAudioLibraryItem:(id<VLCMediaLibraryItemProtocol>)libraryItem
{
    [self showAudioLibrary];
    [(VLCLibraryAudioViewController *)self.librarySegmentViewController presentLibraryItem:libraryItem];
}

- (void)presentVideoLibraryItem:(id<VLCMediaLibraryItemProtocol>)libraryItem
{
    [self showVideoLibrary];
    [(VLCLibraryVideoViewController *)self.librarySegmentViewController presentLibraryItem:libraryItem];
}

- (void)presentGroupLibraryItem:(id<VLCMediaLibraryItemProtocol>)libraryItem
{
    [self showGroupsLibrary];
    [(VLCLibraryAudioViewController *)self.librarySegmentViewController presentLibraryItem:libraryItem];
}

- (void)presentLibraryItem:(id<VLCMediaLibraryItemProtocol>)libraryItem
{
    const BOOL isAudioGroup = [libraryItem isKindOfClass:VLCMediaLibraryAlbum.class] ||
                              [libraryItem isKindOfClass:VLCMediaLibraryArtist.class] ||
                              [libraryItem isKindOfClass:VLCMediaLibraryGenre.class];

    if (isAudioGroup) {
        [self presentAudioLibraryItem:libraryItem];
        return;
    } else if ([libraryItem isKindOfClass:VLCMediaLibraryGroup.class]) {
        [self presentGroupLibraryItem:libraryItem];
        return;
    }

    VLCMediaLibraryMediaItem * const mediaItem = (VLCMediaLibraryMediaItem *)libraryItem;
    const BOOL validMediaItem = mediaItem != nil;
    if (validMediaItem && mediaItem.mediaType == VLC_ML_MEDIA_TYPE_AUDIO) {
        [self presentAudioLibraryItem:libraryItem];
        return;
    } else if (validMediaItem && mediaItem.mediaType == VLC_ML_MEDIA_TYPE_VIDEO) {
        [self presentVideoLibraryItem:libraryItem];
        return;
    }

    NSLog(@"Unknown kind of library item provided, cannot present library view for it: %@", libraryItem.displayString);
}

- (void)goToLocalFolderMrl:(NSString *)mrl
{
    [self goToBrowseSection:self];
    [self.libraryMediaSourceViewController presentLocalFolderMrl:mrl];
}

- (IBAction)sortLibrary:(id)sender
{
    if (!_librarySortingMenuController) {
        _librarySortingMenuController = [[VLCLibrarySortingMenuController alloc] init];
    }
    [NSMenu popUpContextMenu:_librarySortingMenuController.librarySortingMenu withEvent:[NSApp currentEvent] forView:sender];
}

- (void)stopSearchTimer
{
    [self.searchInputTimer invalidate];
    self.searchInputTimer = nil;
}

- (IBAction)filterLibrary:(id)sender
{
    [self stopSearchTimer];
    self.searchInputTimer = [NSTimer scheduledTimerWithTimeInterval:0.3
                                                            target:self
                                                           selector:@selector(updateFilterString)
                                                           userInfo:nil
                                                            repeats:NO];
}

- (void)updateFilterString
{
    [VLCMain.sharedInstance.libraryController filterByString:_librarySearchField.stringValue];
}

- (void)clearFilterString
{
    [self stopSearchTimer];
    _librarySearchField.stringValue = @"";
    [self updateFilterString];
}

- (BOOL)handlePasteBoardFromDragSession:(NSPasteboard *)paste
{
    id propertyList = [paste propertyListForType:NSFilenamesPboardType];
    if (propertyList == nil) {
        return NO;
    }

    NSArray *values = [propertyList sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    NSUInteger valueCount = [values count];
    if (valueCount > 0) {
        NSMutableArray *metadataArray = [NSMutableArray arrayWithCapacity:valueCount];

        for (NSString *filepath in values) {
            VLCOpenInputMetadata *inputMetadata;

            inputMetadata = [VLCOpenInputMetadata inputMetaWithPath:filepath];
            if (!inputMetadata)
                continue;

            [metadataArray addObject:inputMetadata];
        }
        [_playlistController addPlaylistItems:metadataArray];

        return YES;
    }

    return NO;
}

- (IBAction)goToBrowseSection:(id)sender
{
    [self.splitViewController.navSidebarViewController selectSegment:VLCLibraryBrowseSegment];
}

- (IBAction)backwardsNavigationAction:(id)sender
{
    self.videoViewController.view.hidden ? [_navigationStack backwards] : [self disableVideoPlaybackAppearance];
}

- (IBAction)forwardsNavigationAction:(id)sender
{
    [_navigationStack forwards];
}

#pragma mark - video output controlling

- (void)setHasActiveVideo:(BOOL)hasActiveVideo
{
    [super setHasActiveVideo:hasActiveVideo];
    if (hasActiveVideo) {
        [self enableVideoPlaybackAppearance];
    } else if (!self.videoViewController.view.hidden) {
        // If we are switching to audio media then keep the active main video view open
        NSURL * const currentMediaUrl = _playlistController.playerController.URLOfCurrentMediaItem;
        VLCMediaLibraryMediaItem * const mediaItem = [VLCMediaLibraryMediaItem mediaItemForURL:currentMediaUrl];
        const BOOL decorativeViewVisible = mediaItem != nil && mediaItem.mediaType == VLC_ML_MEDIA_TYPE_AUDIO;

        if (!decorativeViewVisible) {
            [self disableVideoPlaybackAppearance];
        }
    } else {
        [self disableVideoPlaybackAppearance];
    }
}

- (void)playerStateChanged:(NSNotification *)notification
{
    if (_playlistController.playerController.playerState == VLC_PLAYER_STATE_STOPPED) {
        [self hideControlsBar];
        return;
    }

    if (self.videoViewController.view.isHidden) {
        [self showControlsBar];
    }
}

- (void)playerTrackSelectionChanged:(NSNotification *)notification
{
    VLCPlayerController * const playerController = self.playerController;
    const BOOL videoTrackDisabled =
        !playerController.videoTracksEnabled || !playerController.selectedVideoTrack.selected;
    const BOOL audioTrackDisabled =
        !playerController.audioTracksEnabled || !playerController.selectedAudioTrack.selected;
    const BOOL currentItemIsAudio =
        playerController.videoTracks.count == 0 && playerController.audioTracks.count > 0;
    const BOOL artworkButtonDisabled =
        (videoTrackDisabled && audioTrackDisabled) || (videoTrackDisabled && !currentItemIsAudio);
    self.artworkButton.enabled = !artworkButtonDisabled;
    self.artworkButton.hidden = artworkButtonDisabled;
    self.controlsBar.thumbnailTrackingView.enabled = !artworkButtonDisabled;
    self.controlsBar.thumbnailTrackingView.viewToHide.hidden = artworkButtonDisabled;
}

- (void)hideControlsBarImmediately
{
    self.controlsBarHeightConstraint.constant = 0;
}

- (void)hideControlsBar
{
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext * const context) {
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        context.duration = VLCLibraryUIUnits.controlsFadeAnimationDuration;
        self.controlsBarHeightConstraint.animator.constant = 0;
    } completionHandler:nil];
}

- (void)showControlsBarImmediately
{
    self.controlsBarHeightConstraint.constant = VLCLibraryUIUnits.libraryWindowControlsBarHeight;
}

- (void)showControlsBar
{
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext * const context) {
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
        context.duration = VLCLibraryUIUnits.controlsFadeAnimationDuration;
        self.controlsBarHeightConstraint.animator.constant = VLCLibraryUIUnits.libraryWindowControlsBarHeight;
    } completionHandler:nil];
}

- (void)presentExternalWindows
{
    VLCVideoOutputProvider * const voutProvider = VLCMain.sharedInstance.voutProvider;
    NSArray<NSWindow *> * const voutWindows = voutProvider.voutWindows.allValues;

    if (voutWindows.count == 0 && self.playerController.videoTracks.count == 0) {
        // If we have no video windows in the video provider but are being asked to present a window
        // then we are dealing with an audio item and the user wants to see the decorative artwork
        // window for said audio
        [VLCMain.sharedInstance.detachedAudioWindow makeKeyAndOrderFront:self];
        return;
    }

    for (NSWindow * const window in voutWindows) {
        [window makeKeyAndOrderFront:self];
    }
}

- (void)presentVideoView
{
    for (NSView *subview in _libraryTargetView.subviews) {
        [subview removeFromSuperview];
    }

    NSLog(@"Presenting video view in main library window.");

    NSView *videoView = self.videoViewController.view;
    videoView.translatesAutoresizingMaskIntoConstraints = NO;
    videoView.hidden = NO;

    [_libraryTargetView addSubview:videoView];
    NSDictionary *dict = NSDictionaryOfVariableBindings(videoView);
    [_libraryTargetView addConstraints:@[
        [NSLayoutConstraint constraintWithItem:videoView
                                     attribute:NSLayoutAttributeTop
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:_libraryTargetView
                                     attribute:NSLayoutAttributeTop
                                    multiplier:1.
                                      constant:0.],
        [NSLayoutConstraint constraintWithItem:videoView
                                     attribute:NSLayoutAttributeBottom
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:_libraryTargetView
                                     attribute:NSLayoutAttributeBottom
                                    multiplier:1.
                                      constant:0.],
        [NSLayoutConstraint constraintWithItem:videoView
                                     attribute:NSLayoutAttributeLeft
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:_libraryTargetView
                                     attribute:NSLayoutAttributeLeft
                                    multiplier:1.
                                      constant:0.],
        [NSLayoutConstraint constraintWithItem:videoView
                                     attribute:NSLayoutAttributeRight
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:_libraryTargetView
                                     attribute:NSLayoutAttributeRight
                                    multiplier:1.
                                      constant:0.]
    ]];
}

- (void)enableVideoPlaybackAppearance
{
    VLCPlayerController * const playerController = self.playerController;
    const BOOL videoTrackDisabled =
        !playerController.videoTracksEnabled || !playerController.selectedVideoTrack.selected;
    const BOOL audioTrackDisabled =
        !playerController.audioTracksEnabled || !playerController.selectedAudioTrack.selected;
    const BOOL currentItemIsAudio =
        playerController.videoTracks.count == 0 && playerController.audioTracks.count > 0;
    if ((videoTrackDisabled && audioTrackDisabled) || (videoTrackDisabled && !currentItemIsAudio)) {
        return;
    }

    const BOOL isEmbedded = var_InheritBool(getIntf(), "embedded-video");
    if (!isEmbedded) {
        [self presentExternalWindows];
        return;
    }

    [self presentVideoView];
    [self enableVideoTitleBarMode];
    [self hideControlsBarImmediately];
    [self.videoViewController showControls];

    self.splitViewController.multifunctionSidebarViewController.mainVideoModeEnabled = YES;

    [self.librarySegmentViewController disconnect];
}

- (void)disableVideoPlaybackAppearance
{
    [self makeFirstResponder:self.splitViewController.multifunctionSidebarViewController.view];
    [VLCMain.sharedInstance.voutProvider updateWindowLevelForHelperWindows:NSNormalWindowLevel];

    // restore alpha value to 1 for the case that macosx-opaqueness is set to < 1
    self.alphaValue = 1.0;
    self.videoViewController.view.hidden = YES;
    [self setViewForSelectedSegment];
    [self disableVideoTitleBarMode];
    [self showControlsBarImmediately];
    self.splitViewController.multifunctionSidebarViewController.mainVideoModeEnabled = NO;
}

- (void)showLoadingOverlay
{
    if ([self.libraryTargetView.subviews containsObject:self.loadingOverlayView]) {
        return;
    }

    self.loadingOverlayView.wantsLayer = YES;
    self.loadingOverlayView.alphaValue = 0.0;

    NSArray * const views = [self.libraryTargetView.subviews arrayByAddingObject:self.loadingOverlayView];
    self.libraryTargetView.subviews = views;
    [self.libraryTargetView addConstraints:self.loadingOverlayViewConstraints];

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext * const context) {
        context.duration = 0.5;
        self.loadingOverlayView.animator.alphaValue = 1.0;
    } completionHandler:nil];
    [self.loadingOverlayView.indicator startAnimation:self];

}

- (void)hideLoadingOverlay
{
    if (![self.libraryTargetView.subviews containsObject:self.loadingOverlayView]) {
        return;
    }

    self.loadingOverlayView.wantsLayer = YES;
    self.loadingOverlayView.alphaValue = 1.0;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext * const context) {
        context.duration = 1.0;
        self.loadingOverlayView.animator.alphaValue = 0.0;
    } completionHandler:^{
        [self.libraryTargetView removeConstraints:self.loadingOverlayViewConstraints];
        NSMutableArray * const views = self.libraryTargetView.subviews.mutableCopy;
        [views removeObject:self.loadingOverlayView];
        self.libraryTargetView.subviews = views.copy;
        [self.loadingOverlayView.indicator stopAnimation:self];
    }];
}

- (void)mouseMoved:(NSEvent *)o_event
{
    if (!self.videoViewController.view.hidden) {
        NSPoint mouseLocation = [o_event locationInWindow];
        NSView *videoView = self.videoViewController.view;
        NSRect videoViewRect = [videoView convertRect:videoView.frame toView:self.contentView];

        if ([self.contentView mouse:mouseLocation inRect:videoViewRect]) {
            [NSNotificationCenter.defaultCenter postNotificationName:VLCVideoWindowShouldShowFullscreenController
                                                                object:self];
        }
    }

    [super mouseMoved:o_event];
}

#pragma mark -
#pragma mark respond to core events

- (void)shouldShowController:(NSNotification *)aNotification
{
    [self makeKeyAndOrderFront:nil];

    if (self.videoViewController.view.isHidden) {
        [self showControlsBar];
        NSView *standardWindowButtonsSuperView = [self standardWindowButton:NSWindowCloseButton].superview;
        standardWindowButtonsSuperView.hidden = NO;
    }
}

- (void)windowWillEnterFullScreen:(NSNotification *)notification
{
    [super windowWillEnterFullScreen:notification];

    if (!self.videoViewController.view.hidden) {
        [self hideControlsBar];
    }
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification
{
    [super windowDidEnterFullScreen:notification];
    if (!self.videoViewController.view.hidden) {
        [self showControlsBar];
    }
}

@end
