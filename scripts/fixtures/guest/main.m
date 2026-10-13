// A minimal guest app for scripts/guest-smoke-test.sh.
//
// It shows one label and, at launch, writes down what the process looks like
// from the inside. Run normally it is an ordinary app; run inside Harbor, the
// report shows whether the engine made Harbor's process pass for this app.

@import UIKit;

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemTealColor;

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

    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
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
    return YES;
}

- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    configuration.delegateClass = SceneDelegate.class;
    return configuration;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
    }
}
