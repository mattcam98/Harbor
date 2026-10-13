@import UIKit;

NS_ASSUME_NONNULL_BEGIN

/// One guest app running in its own process, drawn at the full size of this
/// controller's view.
///
/// The process is LiveContainer's `LiveProcess` extension, and the work of
/// starting it and putting its picture on screen is LiveContainer's
/// `AppSceneViewController`, used unchanged. This class is what Harbor adds:
/// a plain full-size presentation in place of LiveContainer's floating
/// windows, and callbacks in terms Harbor's Swift code can use.
///
/// The view has to stay in a window for as long as the guest runs. To put a
/// guest out of sight, hide the view; do not remove it.
NS_SWIFT_UI_ACTOR
@interface HarborGuestSceneController : UIViewController

/// Whether this copy of Harbor can run guests this way at all: the
/// extension has to be inside the app. Some installers strip extensions.
@property (class, nonatomic, readonly) BOOL isAvailable;

- (instancetype)initWithFolderName:(NSString *)folderName
                         container:(NSString *)container NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSString *)name bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// The guest's folder under `Documents/Applications`.
@property (nonatomic, readonly, copy) NSString *folderName;
/// The data container it runs with.
@property (nonatomic, readonly, copy) NSString *container;
@property (nonatomic, readonly) BOOL isRunning;

/// The guest could not be started, or stopped with an error while starting.
/// Called on the main thread, as are the others.
@property (nonatomic, copy, nullable) void (^onFailed)(NSString *reason);
/// The guest's process has gone, however that happened.
@property (nonatomic, copy, nullable) void (^onExited)(void);

/// Starts the guest. Call once, after the view is in a window.
- (void)start;
/// Asks the guest to quit, and stops it if it has not within a few seconds.
- (void)terminate;
/// Hands the guest a URL, as iOS would to an app that was opened with one.
- (void)openURL:(NSString *)url;

@end

NS_ASSUME_NONNULL_END
