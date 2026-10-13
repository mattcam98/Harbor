// A minimal guest app for scripts/guest-smoke-test.sh.
//
// It shows one label and, at launch, writes down what the process looks like
// from the inside. Run normally it is an ordinary app; run inside Harbor, the
// report shows whether the engine made Harbor's process pass for this app.
//
// Built with LEGACY_LIFECYCLE it is an app from before scenes: the app
// delegate owns the window. Most apps that are not recent are like that.

@import UIKit;

#ifndef LEGACY_LIFECYCLE
#define LEGACY_LIFECYCLE 0
#endif

static UIViewController *MakeRootController(void) {
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = LEGACY_LIFECYCLE ? UIColor.systemIndigoColor : UIColor.systemTealColor;

    UILabel *label = [UILabel new];
    label.text = [NSString stringWithFormat:@"Hello from the guest\n%@", NSBundle.mainBundle.bundleIdentifier];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:controller.view.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor],
        [label.widthAnchor constraintLessThanOrEqualToAnchor:controller.view.widthAnchor constant:-32],
    ]];
    return controller;
}

#if !LEGACY_LIFECYCLE
@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = MakeRootController();
    [self.window makeKeyAndVisible];
}
@end
#endif

@interface AppDelegate : UIResponder <UIApplicationDelegate>
#if LEGACY_LIFECYCLE
@property (nonatomic, strong) UIWindow *window;
#endif
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;

    // A preference written here should land in the guest's container, not Harbor's.
    [NSUserDefaults.standardUserDefaults setObject:@"written by the guest" forKey:@"GuestPreference"];

    NSDictionary *report = @{
        @"bundleIdentifier": NSBundle.mainBundle.bundleIdentifier ?: @"",
        @"bundlePath": NSBundle.mainBundle.bundlePath ?: @"",
        @"executablePath": NSBundle.mainBundle.executablePath ?: @"",
        @"home": NSHomeDirectory(),
        @"documents": documents ?: @"",
        @"processName": NSProcessInfo.processInfo.processName,
        @"argv0": NSProcessInfo.processInfo.arguments.firstObject ?: @"",
        @"infoName": NSBundle.mainBundle.infoDictionary[@"CFBundleName"] ?: @"",
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    [data writeToFile:[documents stringByAppendingPathComponent:@"guest-report.json"] atomically:YES];

    // Written a little later, so it only exists if the app got through its
    // launch and is still running.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [@"running" writeToFile:[documents stringByAppendingPathComponent:@"guest-alive.txt"]
                     atomically:YES encoding:NSUTF8StringEncoding error:nil];
    });

#if LEGACY_LIFECYCLE
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = MakeRootController();
    [self.window makeKeyAndVisible];
#endif
    return YES;
}

#if !LEGACY_LIFECYCLE
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    configuration.delegateClass = SceneDelegate.class;
    return configuration;
}
#endif
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
    }
}
