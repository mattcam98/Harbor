// Built into the tweak loader with LocalNetworkCheck.m, so it runs inside
// guests only.
//
// An app opened full screen runs as Harbor's own process: the engine turns
// the process into the app and never loads Harbor's interface in it. If
// that process is still alive, suspended in the background, iOS hands it
// anything addressed to Harbor, such as the Renew Harbor action of the
// nightly Shortcuts automation. The process cannot run it, and Shortcuts
// reports "an internal error occurred" (seen at 04:00 on 19 November 2026
// with YouTube left open full screen). Tapping Harbor's icon likewise
// brings back the app, not Harbor.
//
// So when such an app goes to the background and has nothing to keep it
// running, the process ends, and the next launch, or the next action, is
// Harbor again. Whether it has something to keep it running is iOS's own
// call: the process holds a background task for as long as it is in the
// background. While the app plays audio or shows Picture in Picture, iOS
// gives it unlimited time and the task never runs out. Once nothing is
// playing, iOS allows about 30 seconds and then calls the task's expiry
// handler, just before it would suspend the app. That is when the process
// ends. Coming back within that time keeps the app as it was.
//
// The app has had didEnterBackground and its own background time to save
// its state by then, as when iOS ends a suspended app to free memory.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Provided by the engine (LiveContainer's utils.h), which the tweak loader
// links.
@interface NSUserDefaults (HarborEngine)
+ (NSDictionary *)guestAppInfo;
+ (bool)isLiveProcess;
@end

// Set to UIBackgroundTaskInvalid when watching starts; that is a variable
// UIKit provides, not a constant.
static UIBackgroundTaskIdentifier HarborHandBackTask;

static void HarborStopWatching(void) {
    if (HarborHandBackTask != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:HarborHandBackTask];
        HarborHandBackTask = UIBackgroundTaskInvalid;
    }
}

static void HarborWatchBackground(void) {
    UIApplication *application = UIApplication.sharedApplication;
    if (HarborHandBackTask != UIBackgroundTaskInvalid
        || application.applicationState != UIApplicationStateBackground) {
        return;
    }
    HarborHandBackTask = [application
        beginBackgroundTaskWithName:@"Harbor: hand the process back when idle"
                  expirationHandler:^{
                      // Unlimited time means something is still playing:
                      // keep watching instead.
                      if (application.backgroundTimeRemaining > 24 * 3600) {
                          HarborStopWatching();
                          HarborWatchBackground();
                          return;
                      }
                      NSLog(@"[Harbor] The app open full screen is idle in the background; "
                            @"ending its process so Harbor opens next time.");
                      exit(0);
                  }];
}

__attribute__((constructor)) static void HarborHandBackWhenIdle(void) {
    // Only an app running as Harbor's own process; one beside Harbor, in
    // LiveProcess, leaves Harbor's process free.
    if (NSUserDefaults.guestAppInfo == nil || NSUserDefaults.isLiveProcess) {
        return;
    }
    HarborHandBackTask = UIBackgroundTaskInvalid;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
                        HarborWatchBackground();
                    }];
    [center addObserverForName:UIApplicationWillEnterForegroundNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
                        HarborStopWatching();
                    }];
}
