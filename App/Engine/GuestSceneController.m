#import "GuestSceneController.h"

#import "AppSceneViewController.h"
#import "utils.h"

// From LiveContainer's UIKitHooks.m.
UIEdgeInsets LCUIEdgeInsetsRotateToOrientation(UIEdgeInsets insets, UIInterfaceOrientation orientation);

// FrontBoard's own way for a host to hear what the app in a scene asks for.
// Present from iOS 18.1 to 27 (checked against the simulators' FrontBoard);
// every use is guarded in case a version drops it.
@interface FBScene (HarborObservation)
- (void)addObserver:(id)observer;
- (void)removeObserver:(id)observer;
- (id)clientSettings;
@end

@interface HarborGuestSceneController () <AppSceneViewControllerDelegate>
@property (nonatomic) AppSceneViewController *scene;
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL exitReported;
@property (nonatomic, readwrite) UIInterfaceOrientationMask guestOrientations;
/// The guest's scene, once this controller is listening to it.
@property (nonatomic, weak) FBScene *observedScene;
@property (nonatomic) BOOL generatesDeviceOrientation;
@end

@implementation HarborGuestSceneController

+ (BOOL)isAvailable {
    NSString *path = [NSBundle.mainBundle.builtInPlugInsPath stringByAppendingPathComponent:@"LiveProcess.appex"];
    return [NSFileManager.defaultManager fileExistsAtPath:path];
}

- (instancetype)initWithFolderName:(NSString *)folderName container:(NSString *)container {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _folderName = [folderName copy];
        _container = [container copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
}

- (BOOL)isRunning {
    return self.scene.isAppRunning;
}

- (void)start {
    if (self.started) return;
    self.started = YES;

    // Creating the scene controller starts the extension. If the extension
    // cannot be found it reports that to the delegate and returns nil.
    self.scene = [[AppSceneViewController alloc] initWithBundleId:self.folderName dataUUID:self.container delegate:self];
    if (!self.scene) return;

    [self addChildViewController:self.scene];
    self.scene.view.frame = self.view.bounds;
    self.scene.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.scene.view];
    [self.scene didMoveToParentViewController:self];

    // Which way the phone is held, as iOS tells an app. An app that keeps
    // its interface upright, such as a video app's player page, still
    // watches this to go full screen when the phone is turned. iOS only
    // tells Harbor, so Harbor passes it on.
    [UIDevice.currentDevice beginGeneratingDeviceOrientationNotifications];
    self.generatesDeviceOrientation = YES;
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(deviceOrientationChanged)
                                               name:UIDeviceOrientationDidChangeNotification
                                             object:nil];
}

- (void)dealloc {
    [self stopObserving];
}

- (void)terminate {
    if (self.scene.isAppRunning) {
        [self.scene terminate];
    } else {
        // Nothing left to stop: say so now instead of waiting for a process
        // that is not there.
        [self.scene appTerminationCleanUp];
        [self reportExit];
    }
}

- (void)openURL:(NSString *)url {
    [self.scene openURLScheme:url];
}

- (void)reportExit {
    if (self.exitReported) return;
    self.exitReported = YES;
    [self stopObserving];
    if (self.onExited) self.onExited();
}

#pragma mark - Following the guest

/// Starts listening to the guest's scene, once it exists. Safe to call at
/// any time and more than once.
- (void)observeScene {
    FBScene *scene = self.scene.presenter.scene;
    if (!scene || scene == self.observedScene || self.exitReported) return;
    if (![scene respondsToSelector:@selector(addObserver:)]) return;
    [self.observedScene removeObserver:self];
    self.observedScene = scene;
    [scene addObserver:self];
    // It may have said already.
    [self clientSettingsChanged];
    [self deviceOrientationChanged];
}

- (void)stopObserving {
    [self.observedScene removeObserver:self];
    self.observedScene = nil;
    [NSNotificationCenter.defaultCenter removeObserver:self name:UIDeviceOrientationDidChangeNotification object:nil];
    if (self.generatesDeviceOrientation) {
        self.generatesDeviceOrientation = NO;
        [UIDevice.currentDevice endGeneratingDeviceOrientationNotifications];
    }
}

/// What the guest asks of its host changed. The part Harbor follows is
/// which orientations its interface supports now: on a phone iOS turns an
/// app only to those, and Harbor's window has to do the same for the guest
/// drawn in it (GuestOrientation.swift).
- (void)clientSettingsChanged {
    FBScene *scene = self.observedScene;
    id clientSettings = [scene respondsToSelector:@selector(clientSettings)] ? scene.clientSettings : nil;
    if (![clientSettings respondsToSelector:@selector(supportedInterfaceOrientations)]) return;
    UIInterfaceOrientationMask mask = [[clientSettings valueForKey:@"supportedInterfaceOrientations"] unsignedIntegerValue];
    if (mask == self.guestOrientations) return;
    self.guestOrientations = mask;
    if (self.onOrientationsChanged) self.onOrientationsChanged();
}

- (void)deviceOrientationChanged {
    FBScene *scene = self.observedScene;
    UIDeviceOrientation orientation = UIDevice.currentDevice.orientation;
    if (!scene || orientation == UIDeviceOrientationUnknown) return;
    [scene updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
        settings.deviceOrientation = orientation;
    }];
}

#pragma mark - FBSceneObserver

// Which of the two FrontBoard calls depends on the iOS version; it may call
// both. Repeats change nothing.
- (void)scene:(id)scene didUpdateClientSettings:(id)update {
    [self clientSettingsChangedOnMainThread];
}

- (void)scene:(id)scene didUpdateClientSettingsWithDiff:(id)diff oldClientSettings:(id)oldSettings transitionContext:(id)context {
    [self clientSettingsChangedOnMainThread];
}

- (void)clientSettingsChangedOnMainThread {
    if (NSThread.isMainThread) {
        [self clientSettingsChanged];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ [self clientSettingsChanged]; });
    }
}

#pragma mark - AppSceneViewControllerDelegate

- (void)appSceneVC:(AppSceneViewController *)vc didInitializeWithError:(NSError *)error {
    // Arrives on whichever thread the extension machinery used. A nil error
    // only means the process exists. The guest's scene is made next, on the
    // main queue, just after this returns: listen to it once it is there.
    if (!error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_async(dispatch_get_main_queue(), ^{ [self observeScene]; });
        });
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [vc appTerminationCleanUp];
        if (self.onFailed) self.onFailed(error.localizedDescription);
    });
}

- (void)appSceneVCAppDidExit:(AppSceneViewController *)vc {
    [self reportExit];
}

- (void)appSceneVCWillActivateScene:(AppSceneViewController *)vc {
    // The first settings the guest sees: size, safe area, appearance.
    [self appSceneVC:vc didUpdateFromSettings:vc.presenter.scene.settings.mutableCopy transitionContext:nil lifecycleActionType:0];
    [self observeScene];
}

/// Harbor's own scene changed (rotation, light or dark, size). Pass on what
/// the guest should follow, so that it lays itself out as the app that fills
/// the screen, which it is.
- (void)appSceneVC:(AppSceneViewController *)vc
    didUpdateFromSettings:(UIMutableApplicationSceneSettings *)hostSettings
        transitionContext:(id)context
      lifecycleActionType:(uint32_t)actionType {
    [self.scene updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
        settings.userInterfaceStyle = hostSettings.userInterfaceStyle;
        settings.interfaceOrientation = hostSettings.interfaceOrientation;
        settings.deviceOrientation = hostSettings.deviceOrientation;
        // Into the background with Harbor, as an app goes when the user
        // leaves it: that is when a video app starts Picture in Picture.
        settings.foreground = hostSettings.isForeground;

        UIEdgeInsets insets = self.view.window.safeAreaInsets;
        settings.peripheryInsets = insets;
        if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
            settings.safeAreaInsetsPortrait = insets;
        } else {
            UIInterfaceOrientation orientation = self.view.window.windowScene.interfaceOrientation;
            settings.safeAreaInsetsPortrait = LCUIEdgeInsetsRotateToOrientation(insets, orientation);
        }

        // The frame is always given as if upright.
        CGSize size = self.view.bounds.size;
        if (UIInterfaceOrientationIsLandscape(hostSettings.interfaceOrientation)) {
            settings.frame = CGRectMake(0, 0, size.height, size.width);
        } else {
            settings.frame = CGRectMake(0, 0, size.width, size.height);
        }
    }];
}

@end
