// Built into the tweak loader, which every guest loads before it starts, so
// it runs inside guests only, never in Harbor's own interface.
//
// YouTube decides whether it may look for TVs by sending an SSDP search
// (multicast UDP to 239.255.255.250) and seeing whether it goes out
// (MDXLocalNetworkPermissions, read from YouTube 21.02.3). iOS lets an app
// send multicast only with Apple's multicast entitlement, which Harbor
// cannot have: a free Apple ID cannot get it, and a guest runs with
// Harbor's entitlements. So the probe always fails, YouTube records
// "denied" (MDXLocalNetworkPermissionsStatus = 2) and sends the user to a
// Settings page a guest does not have, without ever looking for a TV.
//
// The probe only stands in for asking iOS. Cast devices are found through
// Bonjour, which Harbor allows (NSBonjourServices in project.yml) once
// Harbor itself has local network access. So for this one class, report
// access as granted and let discovery run. TVs that are found only by SSDP
// or DIAL, and not through Google Cast, still cannot be found.
//
// A YouTube without this class, or without one of these methods, is left
// as it is.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// The status YouTube's own isAuthorized compares with, and passes to the
// completion of verifyAccessWithCompletion: when no check is needed.
static const NSInteger HarborLocalNetworkGranted = 1;
static NSString *const HarborLocalNetworkStatusKey = @"MDXLocalNetworkPermissionsStatus";

typedef void (^HarborStatusCompletion)(NSInteger status);

static BOOL HarborYes(id self, SEL _cmd) { return YES; }
static BOOL HarborNo(id self, SEL _cmd) { return NO; }
static NSInteger HarborGranted(id self, SEL _cmd) { return HarborLocalNetworkGranted; }

static void HarborReportGranted(id self, SEL _cmd, HarborStatusCompletion completion) {
    // Replace a "denied" recorded before this fix, which the app reads at
    // other times too.
    [NSUserDefaults.standardUserDefaults setInteger:HarborLocalNetworkGranted
                                             forKey:HarborLocalNetworkStatusKey];
    if (completion) {
        completion(HarborLocalNetworkGranted);
    }
}

static void HarborReplace(Class cls, NSString *selector, IMP replacement) {
    SEL sel = NSSelectorFromString(selector);
    Method method = class_getInstanceMethod(cls, sel);
    if (method) {
        class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
    }
}

static BOOL HarborFixYouTubeLocalNetworkCheck(void) {
    Class cls = objc_getClass("MDXLocalNetworkPermissions");
    if (!cls) {
        return NO;
    }
    HarborReplace(cls, @"isAuthorized", (IMP)HarborYes);
    HarborReplace(cls, @"lastKnownPermissionsStatus", (IMP)HarborGranted);
    HarborReplace(cls, @"localNetworkPermissionCheckRequired", (IMP)HarborNo);
    // Every way in to the probe: the public one and the three it uses.
    for (NSString *selector in @[
             @"verifyAccessWithCompletion:",
             @"verifyAccessWithCompletionInternal:",
             @"verifyAccessFromPollingWithCompletionInternal:",
             @"pollToVerifyAccessWithCompletionInternal:",
         ]) {
        HarborReplace(cls, selector, (IMP)HarborReportGranted);
    }
    NSLog(@"[Harbor] Reporting local network access to YouTube's casting as granted; "
          @"its multicast check cannot pass inside Harbor.");
    return YES;
}

__attribute__((constructor)) static void HarborGuestFixes(void) {
    if (HarborFixYouTubeLocalNetworkCheck()) {
        return;
    }
    // The guest's classes are normally registered before this runs. If the
    // class arrives later, try once more when the app has finished launching.
    __block id observer = [NSNotificationCenter.defaultCenter
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
                    HarborFixYouTubeLocalNetworkCheck();
                    [NSNotificationCenter.defaultCenter removeObserver:observer];
                    observer = nil;
                }];
}
