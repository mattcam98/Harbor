#import "GuestSceneController.h"

#import "AppSceneViewController.h"
#import "utils.h"

// From LiveContainer's UIKitHooks.m.
UIEdgeInsets LCUIEdgeInsetsRotateToOrientation(UIEdgeInsets insets, UIInterfaceOrientation orientation);

@interface HarborGuestSceneController () <AppSceneViewControllerDelegate>
@property (nonatomic) AppSceneViewController *scene;
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL exitReported;
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
    self.view.backgroundColor = UIColor.blackColor;
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
    if (self.onExited) self.onExited();
}

#pragma mark - AppSceneViewControllerDelegate

- (void)appSceneVC:(AppSceneViewController *)vc didInitializeWithError:(NSError *)error {
    // Arrives on whichever thread the extension machinery used. A nil error
    // only means the process exists; there is nothing to do for that yet.
    if (!error) return;
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
        settings.foreground = YES;

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
