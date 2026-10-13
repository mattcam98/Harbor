// LiveContainer's scene controller asks `LCUtils`, a class from
// LiveContainer's own interface, where the extension is. Harbor does not
// build that interface, so this supplies the one answer it needs. The rest
// of the class as its header declares it does not exist here.

#import "LCUtils.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wobjc-property-implementation"

@implementation LCUtils

+ (NSString *)liveProcessBundleIdentifier {
    NSString *path = [NSBundle.mainBundle.builtInPlugInsPath stringByAppendingPathComponent:@"LiveProcess.appex"];
    return [NSBundle bundleWithPath:path].bundleIdentifier;
}

@end

#pragma clang diagnostic pop
