#include "mainui.hpp"

#include <cassert>

#include "medialibrary/medialib.hpp"
#include "medialibrary/mlqmltypes.hpp"
#include "medialibrary/mlcustomcover.hpp"
#include "medialibrary/mlalbummodel.hpp"
#include "medialibrary/mlartistmodel.hpp"
#include "medialibrary/mlalbumtrackmodel.hpp"
#include "medialibrary/mlgenremodel.hpp"
#include "medialibrary/mlurlmodel.hpp"
#include "medialibrary/mlvideomodel.hpp"
#include "medialibrary/mlrecentsmodel.hpp"
#include "medialibrary/mlrecentsvideomodel.hpp"
#include "medialibrary/mlfoldersmodel.hpp"
#include "medialibrary/mlvideogroupsmodel.hpp"
#include "medialibrary/mlvideofoldersmodel.hpp"
#include "medialibrary/mlplaylistlistmodel.hpp"
#include "medialibrary/mlplaylistmodel.hpp"
#include "medialibrary/mlplaylist.hpp"
#include "medialibrary/mlbookmarkmodel.hpp"

#include "player/player_controller.hpp"
#include "player/player_controlbar_model.hpp"
#include "player/control_list_model.hpp"
#include "player/control_list_filter.hpp"
#include "player/delay_estimator.hpp"

#include "dialogs/toolbar/controlbar_profile_model.hpp"
#include "dialogs/toolbar/controlbar_profile.hpp"

#include "playlist/playlist_model.hpp"
#include "playlist/playlist_controller.hpp"

#include "util/item_key_event_filter.hpp"
#include "util/imageluminanceextractor.hpp"
#include "util/keyhelper.hpp"
#include "style/systempalette.hpp"
#include "util/navigation_history.hpp"
#include "util/flickable_scroll_handler.hpp"
#include "util/color_svg_image_provider.hpp"
#include "util/effects_image_provider.hpp"
#include "util/vlcaccess_image_provider.hpp"
#include "util/csdbuttonmodel.hpp"
#include "util/vlctick.hpp"
#include "util/list_selection_model.hpp"

#include "dialogs/help/aboutmodel.hpp"
#include "dialogs/dialogs_provider.hpp"
#include "dialogs/dialogs/dialogmodel.hpp"

#include "network/networkmediamodel.hpp"
#include "network/networkdevicemodel.hpp"
#include "network/networksourcesmodel.hpp"
#include "network/servicesdiscoverymodel.hpp"
#include "network/standardpathmodel.hpp"

#include "menus/qml_menu_wrapper.hpp"

#include "widgets/native/csdthemeimage.hpp"
#include "widgets/native/roundimage.hpp"
#include "widgets/native/navigation_attached.hpp"
#include "widgets/native/viewblockingrectangle.hpp"
#if QT_VERSION < QT_VERSION_CHECK(6, 4, 0)
#include "widgets/native/doubleclickignoringitem.hpp"
#else
// QQuickItem already ignores double click, starting
// with Qt 6.4.0:
#define DoubleClickIgnoringItem QQuickItem
#endif

#include "videosurface.hpp"
#include "mainctx.hpp"
#include "mainctx_submodels.hpp"

#include <QScreen>

using  namespace vlc::playlist;

namespace {

template<class T>
class SingletonRegisterHelper
{
    static QPointer<T> m_instance;

public:
    static QObject* callback(QQmlEngine *engine, QJSEngine *)
    {
        assert(m_instance);
        engine->setObjectOwnership(m_instance, QQmlEngine::ObjectOwnership::CppOwnership);
        return m_instance;
    }

    static void setInstance(T* instance)
    {
        assert(!m_instance);
        m_instance = instance;
    }

    static T* getInstance()
    {
        return m_instance;
    }
};
template<class T>
QPointer<T> SingletonRegisterHelper<T>::m_instance = nullptr;

} // anonymous namespace


MainUI::MainUI(qt_intf_t *p_intf, MainCtx *mainCtx, QWindow* interfaceWindow,  QObject *parent)
    : QObject(parent)
    , m_intf(p_intf)
    , m_mainCtx(mainCtx)
    , m_interfaceWindow(interfaceWindow)
{
    assert(m_intf);
    assert(m_mainCtx);
    assert(m_interfaceWindow);

    SingletonRegisterHelper<MainCtx>::setInstance(mainCtx);

    assert(m_intf->p_mainPlayerController);
    SingletonRegisterHelper<PlayerController>::setInstance(m_intf->p_mainPlayerController);

    assert(m_intf->p_mainPlaylistController);
    SingletonRegisterHelper<PlaylistController>::setInstance(m_intf->p_mainPlaylistController);

    assert(VLCDialogModel::getInstance<false>());
    SingletonRegisterHelper<VLCDialogModel>::setInstance(VLCDialogModel::getInstance<false>());
    assert(DialogsProvider::getInstance());
    SingletonRegisterHelper<DialogsProvider>::setInstance(DialogsProvider::getInstance());

    assert(DialogErrorModel::getInstance<false>());
    SingletonRegisterHelper<DialogErrorModel>::setInstance( DialogErrorModel::getInstance<false>() );

    SingletonRegisterHelper<NavigationHistory>::setInstance( new NavigationHistory(this) );
    SingletonRegisterHelper<SystemPalette>::setInstance( new SystemPalette(this) );
    SingletonRegisterHelper<QmlKeyHelper>::setInstance( new QmlKeyHelper(this) );
    SingletonRegisterHelper<SVGColorImage>::setInstance( new SVGColorImage(this) );
    SingletonRegisterHelper<VLCAccessImage>::setInstance( new VLCAccessImage(this) );

    if (m_mainCtx->hasMediaLibrary())
    {
        assert(m_mainCtx->getMediaLibrary());
        SingletonRegisterHelper<MediaLib>::setInstance(m_mainCtx->getMediaLibrary());
    }

    registerQMLTypes();
}

MainUI::~MainUI()
{
    qmlClearTypeRegistrations();
}

bool MainUI::setup(QQmlEngine* engine)
{
    engine->setOutputWarningsToStandardError(false);
    connect(engine, &QQmlEngine::warnings, this, &MainUI::onQmlWarning);

    if (m_mainCtx->hasMediaLibrary())
    {
        engine->addImageProvider(MLCustomCover::providerId, new MLCustomCover(m_mainCtx->getMediaLibrary()));
    }

#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
    engine->addImportPath(":/qt/qml");
#endif

    SingletonRegisterHelper<EffectsImageProvider>::setInstance(new EffectsImageProvider(engine));
    engine->addImageProvider(QStringLiteral("svgcolor"), new SVGColorImageImageProvider());
    engine->addImageProvider(QStringLiteral("vlcaccess"), new VLCAccessImageProvider());

    m_component  = new QQmlComponent(engine, QStringLiteral("qrc:/qt/qml/VLC/MainInterface/MainInterface.qml"), QQmlComponent::PreferSynchronous, engine);
    if (m_component->isLoading())
    {
        msg_Warn(m_intf, "component is still loading");
    }

    if (m_component->isError())
    {
        for(auto& error: m_component->errors())
            msg_Err(m_intf, "qml loading %s %s:%u", qtu(error.description()), qtu(error.url().toString()), error.line());
#ifdef QT_STATIC
            assert( !"Missing qml modules from qt contribs." );
#else
            msg_Err( m_intf, "Install missing modules using your packaging tool" );
#endif
        return false;
    }
    return true;
}

QQuickItem* MainUI::createRootItem()
{
    QObject* rootObject = m_component->create();

    if (m_component->isError())
    {
        for(auto& error: m_component->errors())
            msg_Err(m_intf, "qml loading %s %s:%u", qtu(error.description()), qtu(error.url().toString()), error.line());
        return nullptr;
    }

    if (rootObject == nullptr)
    {
        msg_Err(m_intf, "unable to create main interface, no root item");
        return nullptr;
    }
    m_rootItem = qobject_cast<QQuickItem*>(rootObject);
    if (!m_rootItem)
    {
        msg_Err(m_intf, "unexpected type of qml root item");
        return nullptr;
    }

    return m_rootItem;
}

void MainUI::registerQMLTypes()
{
    {
        const char* uri = "VLC.MainInterface";
        const int versionMajor = 1;
        const int versionMinor = 0;

        // @uri VLC.MainInterface
        qmlRegisterSingletonType<MainCtx>(uri, versionMajor, versionMinor, "MainCtx", SingletonRegisterHelper<MainCtx>::callback);
        qmlRegisterUncreatableType<SearchCtx>(uri, versionMajor, versionMinor, "SearchCtx", "");
        qmlRegisterUncreatableType<SortCtx>(uri, versionMajor, versionMinor, "SortCtx", "");
        qmlRegisterSingletonType<NavigationHistory>(uri, versionMajor, versionMinor, "History", SingletonRegisterHelper<NavigationHistory>::callback);
        qmlRegisterUncreatableType<QAbstractItemModel>(uri, versionMajor, versionMinor, "QtAbstractItemModel", "");
        qmlRegisterUncreatableType<QWindow>(uri, versionMajor, versionMinor, "QtWindow", "");
        qmlRegisterUncreatableType<QScreen>(uri, versionMajor, versionMinor, "QtScreen", "");
        qmlRegisterUncreatableType<VLCTick>(uri, versionMajor, versionMinor, "vlcTick", "");
        qmlRegisterType<VideoSurface>(uri, versionMajor, versionMinor, "VideoSurface");
        qmlRegisterUncreatableType<BaseModel>( uri, versionMajor, versionMinor, "BaseModel", "Base Model is uncreatable." );
        qmlRegisterUncreatableType<VLCVarChoiceModel>(uri, versionMajor, versionMinor, "VLCVarChoiceModel", "generic variable with choice model" );
        qmlRegisterUncreatableType<CSDButton>(uri, versionMajor, versionMinor, "CSDButton", "");
        qmlRegisterUncreatableType<CSDButtonModel>(uri, versionMajor, versionMinor, "CSDButtonModel", "has CSD buttons and provides for communicating CSD events between UI and backend");
        qmlRegisterUncreatableType<NavigationAttached>( uri, versionMajor, versionMinor, "Navigation", "Navigation is only available via attached properties");

        qmlRegisterModule(uri, versionMajor, versionMinor);
        qmlProtectModule(uri, versionMajor);
    }

    {
        const char* uri = "VLC.Dialogs";
        const int versionMajor = 1;
        const int versionMinor = 0;

        // @uri VLC.Dialogs
        qmlRegisterType<AboutModel>( uri, versionMajor, versionMinor, "AboutModel" );
        qmlRegisterType<VLCDialog>( uri, versionMajor, versionMinor, "VLCDialog" );
        qmlRegisterSingletonType<VLCDialogModel>(uri, versionMajor, versionMinor, "VLCDialogModel", SingletonRegisterHelper<VLCDialogModel>::callback);
        qmlRegisterUncreatableType<DialogId>( uri, versionMajor, versionMinor, "dialogId", "");
        qmlRegisterSingletonType<DialogsProvider>(uri, versionMajor, versionMinor, "DialogsProvider", SingletonRegisterHelper<DialogsProvider>::callback);
        qmlRegisterSingletonType<DialogErrorModel>(uri, versionMajor, versionMinor, "DialogErrorModel", SingletonRegisterHelper<DialogErrorModel>::callback);

        qmlRegisterModule(uri, versionMajor, versionMinor);
        qmlProtectModule(uri, versionMajor);
    }

    {
        const char* uri = "VLC.Menus";
        const int versionMajor = 1;
        const int versionMinor = 0;

        // @uri VLC.Menus
        qmlRegisterType<StringListMenu>( uri, versionMajor, versionMinor, "StringListMenu" );
        qmlRegisterType<SortMenu>( uri, versionMajor, versionMinor, "SortMenu" );
        qmlRegisterType<SortMenuVideo>( uri, versionMajor, versionMinor, "SortMenuVideo" );
        qmlRegisterType<QmlGlobalMenu>( uri, versionMajor, versionMinor, "QmlGlobalMenu" );
        qmlRegisterType<QmlMenuBar>( uri, versionMajor, versionMinor, "QmlMenuBar" );

        qmlRegisterModule(uri, versionMajor, versionMinor);
        qmlProtectModule(uri, versionMajor);
    }

    {
        const char* uri = "VLC.Player";
        const int versionMajor = 1;
        const int versionMinor = 0;

        // @uri VLC.Player
        qmlRegisterUncreatableType<TrackListModel>(uri, versionMajor, versionMinor, "TrackListModel", "available tracks of a media (audio/video/sub)" );
        qmlRegisterUncreatableType<TitleListModel>(uri, versionMajor, versionMinor, "TitleListModel", "available titles of a media" );
        qmlRegisterUncreatableType<ChapterListModel>(uri, versionMajor, versionMinor, "ChapterListModel", "available chapters of a media" );
        qmlRegisterUncreatableType<ProgramListModel>(uri, versionMajor, versionMinor, "ProgramListModel", "available programs of a media" );
        qmlRegisterSingletonType<PlayerController>(uri, versionMajor, versionMinor, "Player", SingletonRegisterHelper<PlayerController>::callback);

        qmlRegisterType<QmlBookmarkMenu>( uri, versionMajor, versionMinor, "QmlBookmarkMenu" );
        qmlRegisterType<QmlProgramMenu>( uri, versionMajor, versionMinor, "QmlProgramMenu" );
        qmlRegisterType<QmlRendererMenu>( uri, versionMajor, versionMinor, "QmlRendererMenu" );
        qmlRegisterType<QmlSubtitleMenu>( uri, versionMajor, versionMinor, "QmlSubtitleMenu" );
        qmlRegisterType<QmlAudioMenu>( uri, versionMajor, versionMinor, "QmlAudioMenu" );
        qmlRegisterType<QmlAudioContextMenu>( uri, versionMajor, versionMinor, "QmlAudioContextMenu" );

        qmlRegisterModule(uri, versionMajor, versionMinor);
        qmlProtectModule(uri, versionMajor);
    }

    {
        const char* uri = "VLC.PlayerControls";
        const int versionMajor = 1;
        const int versionMinor = 0;

        // @uri VLC.PlayerControls
        qmlRegisterUncreatableType<ControlbarProfileModel>(uri, versionMajor, versionMinor, "ControlbarProfileModel", "");
        qmlRegisterUncreatableType<ControlbarProfile>(uri, versionMajor, versionMinor, "ControlbarProfile", "");
        qmlRegisterUncreatableType<PlayerControlbarModel>(uri, versionMajor, versionMinor, "PlayerControlbarModel", "");
        qmlRegisterUncreatableType<ControlListModel>( uri, versionMajor, versionMinor, "ControlListModel", "" );
        qmlRegisterType<ControlListFilter>(uri, versionMajor, versionMinor, "ControlListFilter");
        qmlRegisterSingletonType(uri, versionMajor, versionMinor, "PlayerListModel", PlayerControlbarModel::getPlaylistIdentifierListModel);


        qmlRegisterModule(uri, versionMajor, versionMinor);
        qmlProtectModule(uri, versionMajor);
    }

    {
        const char* uri = "VLC.Playlist";
        const int versionMajor = 1;
        const int versionMinor = 0;

        // @uri VLC.Playlist
        qmlRegisterUncreatableType<PlaylistItem>(uri, versionMajor, versionMinor, "playlistItem", "");
        qmlRegisterType<PlaylistListModel>( uri, versionMajor, versionMinor, "PlaylistListModel" );
        qmlRegisterType<PlaylistController>( uri, versionMajor, versionMinor, "PlaylistController" );
        qmlRegisterType<PlaylistContextMenu>( uri, versionMajor, versionMinor, "PlaylistContextMenu" );
        qmlRegisterSingletonType<PlaylistController>(uri, versionMajor, versionMinor, "MainPlaylistController", SingletonRegisterHelper<PlaylistController>::callback);

        qmlRegisterModule(uri, versionMajor, versionMinor);
        qmlProtectModule(uri, versionMajor);
    }

    {
        const char* uri = "VLC.Network";
        const int versionMajor = 1;
        const int versionMinor = 0;

        // @uri VLC.Network
        qmlRegisterType<NetworkMediaModel>( uri, versionMajor, versionMinor, "NetworkMediaModel");
        qmlRegisterType<NetworkDeviceModel>( uri, versionMajor, versionMinor, "NetworkDeviceModel");
        qmlRegisterType<NetworkSourcesModel>( uri, versionMajor, versionMinor, "NetworkSourcesModel");
        qmlRegisterType<ServicesDiscoveryModel>( uri, versionMajor, versionMinor, "ServicesDiscoveryModel");
        qmlRegisterType<StandardPathModel>( uri, versionMajor, versionMinor, "StandardPathModel");
        qmlRegisterType<MLFoldersModel>( uri, versionMajor, versionMinor, "MLFolderModel");

        qmlRegisterType<NetworkMediaContextMenu>( uri, versionMajor, versionMinor, "NetworkMediaContextMenu" );
        qmlRegisterType<NetworkDeviceContextMenu>( uri, versionMajor, versionMinor, "NetworkDeviceContextMenu" );

        qmlRegisterModule(uri, versionMajor, versionMinor);
        qmlProtectModule(uri, versionMajor);
    }

    {
        const char* uri = "VLC.Style";
        const int versionMajor = 1;
        const int versionMinor = 0;

        // @uri VLC.Style
        qmlRegisterUncreatableType<ColorSchemeModel>(uri, versionMajor, versionMinor, "ColorSchemeModel", "");
        qmlRegisterType<ColorContext>(uri, versionMajor, versionMinor, "ColorContext");
        qmlRegisterUncreatableType<ColorProperty>(uri, versionMajor, versionMinor, "colorProperty", "");
        qmlRegisterType<SystemPalette>(uri, versionMajor, versionMinor, "SystemPalette");

        qmlRegisterModule(uri, versionMajor, versionMinor);
        qmlProtectModule(uri, versionMajor);
    }

    {
        const char* uri = "VLC.Util";
        const int versionMajor = 1;
        const int versionMinor = 0;

        // @uri VLC.Util
        qmlRegisterSingletonType<QmlKeyHelper>(uri, versionMajor, versionMinor, "KeyHelper", SingletonRegisterHelper<QmlKeyHelper>::callback);
        qmlRegisterSingletonType<EffectsImageProvider>(uri, versionMajor, versionMinor, "Effects", SingletonRegisterHelper<EffectsImageProvider>::callback);
        qmlRegisterUncreatableType<SVGColorImageBuilder>(uri, versionMajor, versionMinor, "SVGColorImageBuilder", "");
        qmlRegisterSingletonType<SVGColorImage>(uri, versionMajor, versionMinor, "SVGColorImage", SingletonRegisterHelper<SVGColorImage>::callback);
        qmlRegisterSingletonType<VLCAccessImage>(uri, versionMajor, versionMinor, "VLCAccessImage", SingletonRegisterHelper<VLCAccessImage>::callback);
        qmlRegisterType<DelayEstimator>( uri, versionMajor, versionMinor, "DelayEstimator" );

        qmlRegisterType<ImageLuminanceExtractor>( uri, versionMajor, versionMinor, "ImageLuminanceExtractor");

        qmlRegisterType<ItemKeyEventFilter>( uri, versionMajor, versionMinor, "KeyEventFilter" );
        qmlRegisterType<FlickableScrollHandler>( uri, versionMajor, versionMinor, "FlickableScrollHandler" );
        qmlRegisterType<ListSelectionModel>( uri, versionMajor, versionMinor, "ListSelectionModel" );
        qmlRegisterType<DoubleClickIgnoringItem>( uri, versionMajor, versionMinor, "DoubleClickIgnoringItem" );

        qmlRegisterModule(uri, versionMajor, versionMinor);
        qmlProtectModule(uri, versionMajor);
    }

    {
        const char* uri = "VLC.Widgets";
        const int versionMajor = 1;
        const int versionMinor = 0;

        // @uri VLC.Widgets
        qmlRegisterType<RoundImage>( uri, versionMajor, versionMinor, "RoundImage" );
        qmlRegisterType<CSDThemeImage>(uri, versionMajor, versionMinor, "CSDThemeImage");
        qmlRegisterType<ViewBlockingRectangle>( uri, versionMajor, versionMinor, "ViewBlockingRectangle" );

        qmlRegisterModule(uri, versionMajor, versionMinor);
        qmlProtectModule(uri, versionMajor);
    }

    if (m_mainCtx->hasMediaLibrary())
    {
        const char* uri = "VLC.MediaLibrary";
        const int versionMajor = 1;
        const int versionMinor = 0;

        // @uri VLC.MediaLibrary
        qmlRegisterSingletonType<MediaLib>(uri, versionMajor, versionMinor, "MediaLib", SingletonRegisterHelper<MediaLib>::callback);

        qmlRegisterUncreatableType<MLItemId>( uri, versionMajor, versionMinor, "mediaId", "");
        qmlRegisterUncreatableType<MLBaseModel>( uri, versionMajor, versionMinor, "MLBaseModel", "ML Base Model is uncreatable." );
        qmlRegisterType<MLAlbumModel>( uri, versionMajor, versionMinor, "MLAlbumModel" );
        qmlRegisterType<MLArtistModel>( uri, versionMajor, versionMinor, "MLArtistModel" );
        qmlRegisterType<MLAlbumTrackModel>( uri, versionMajor, versionMinor, "MLAlbumTrackModel" );
        qmlRegisterType<MLGenreModel>( uri, versionMajor, versionMinor, "MLGenreModel" );
        qmlRegisterType<MLUrlModel>( uri, versionMajor, versionMinor, "MLUrlModel" );
        qmlRegisterType<MLVideoModel>( uri, versionMajor, versionMinor, "MLVideoModel" );
        qmlRegisterType<MLRecentsVideoModel>( uri, versionMajor, versionMinor, "MLRecentsVideoModel" );
        qmlRegisterType<MLVideoGroupsModel>( uri, versionMajor, versionMinor, "MLVideoGroupsModel" );
        qmlRegisterType<MLVideoFoldersModel>( uri, versionMajor, versionMinor, "MLVideoFoldersModel" );
        qmlRegisterType<MLPlaylistListModel>( uri, versionMajor, versionMinor, "MLPlaylistListModel" );
        qmlRegisterType<MLPlaylistModel>( uri, versionMajor, versionMinor, "MLPlaylistModel" );
        qmlRegisterType<MLBookmarkModel>( uri, versionMajor, versionMinor, "MLBookmarkModel" );

        qmlRegisterType<NetworkMediaModel>( uri, versionMajor, versionMinor, "NetworkMediaModel");
        qmlRegisterType<NetworkDeviceModel>( uri, versionMajor, versionMinor, "NetworkDeviceModel");
        qmlRegisterType<NetworkSourcesModel>( uri, versionMajor, versionMinor, "NetworkSourcesModel");
        qmlRegisterType<ServicesDiscoveryModel>( uri, versionMajor, versionMinor, "ServicesDiscoveryModel");
        qmlRegisterType<MLFoldersModel>( uri, versionMajor, versionMinor, "MLFolderModel");
        qmlRegisterType<MLRecentsModel>( uri, versionMajor, versionMinor, "MLRecentModel" );

        qmlRegisterType<PlaylistListContextMenu>( uri, versionMajor, versionMinor, "PlaylistListContextMenu" );
        qmlRegisterType<PlaylistMediaContextMenu>( uri, versionMajor, versionMinor, "PlaylistMediaContextMenu" );

        qmlRegisterModule(uri, versionMajor, versionMinor);
        qmlProtectModule(uri, versionMajor);
    }

#if QT_VERSION < QT_VERSION_CHECK(6, 5, 0)
    // Dummy QtQuick.Effects module
    qmlRegisterModule("QtQuick.Effects", 0, 0);
    // Do not protect, types can still be registered.
#endif
}

void MainUI::onQmlWarning(const QList<QQmlError>& qmlErrors)
{
    for( const auto& error: qmlErrors )
    {
        vlc_log_type type;

        switch( error.messageType() )
        {
        case QtInfoMsg:
            type = VLC_MSG_INFO; break;
        case QtWarningMsg:
            type = VLC_MSG_WARN; break;
        case QtCriticalMsg:
        case QtFatalMsg:
            type = VLC_MSG_ERR; break;
        case QtDebugMsg:
        default:
            type = VLC_MSG_DBG;
        }

        msg_Generic( m_intf,
                     type,
                     "qml message %s:%i %s",
                     qtu(error.url().toString()),
                     error.line(),
                     qtu(error.description()) );
    }
}
