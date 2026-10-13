import Foundation
import ObjectiveC

/// The few points where Harbor's interface talks to LiveContainer's engine.
///
/// The engine is already loaded when the interface starts (it is what loaded
/// the interface), so its classes and functions are looked up at run time
/// instead of being linked against. Each lookup that fails is reported, not
/// assumed.
enum EngineBridge {
    enum Failure: Error, Equatable {
        /// The engine is not in this process, or no longer has this entry point.
        case engineUnavailable(String)
    }

    // MARK: Launching

    /// Tells the engine which guest to become, then asks iOS to start Harbor
    /// again. This process is killed once the new one is on its way, so on
    /// success this call does not return to anything that matters.
    static func launch(folderName: String, container: String? = nil) throws {
        guard
            let utilities = NSClassFromString("LCSharedUtils"),
            let method = class_getClassMethod(utilities, launchSelector)
        else {
            throw Failure.engineUnavailable("LCSharedUtils launchToGuestAppWithClassicMode:")
        }

        let defaults = UserDefaults.standard
        defaults.set(folderName, forKey: "selected")
        if let container {
            defaults.set(container, forKey: "selectedContainer")
        } else {
            defaults.removeObject(forKey: "selectedContainer")
        }

        typealias Launch = @convention(c) (AnyClass, Selector, UInt) -> ObjCBool
        let launch = unsafeBitCast(method_getImplementation(method), to: Launch.self)
        _ = launch(utilities, launchSelector, 0)
    }

    private static let launchSelector = NSSelectorFromString("launchToGuestAppWithClassicMode:")

    /// What the engine recorded when a guest failed to start. Reading it
    /// clears it, so it is shown once.
    static func takeLastError() -> String? {
        let defaults = UserDefaults.standard
        guard let error = defaults.string(forKey: "error") else { return nil }
        defaults.removeObject(forKey: "error")
        return error
    }

    // MARK: Signed guests

    /// Tells the engine whether guests are signed. With this set it loads
    /// them as ordinary signed code; without it, it requires a debugger to be
    /// attached, and refuses outright on iOS 26 and later.
    ///
    /// The engine only checks that the value exists. Its name is historical:
    /// LiveContainer stored the certificate's password here. Harbor stores a
    /// fixed marker and keeps the certificate in the keychain.
    static func setGuestsAreSigned(_ signed: Bool) {
        let defaults = engineSharedDefaults()
        if signed {
            defaults.set("harbor", forKey: "LCCertificatePassword")
        } else {
            defaults.removeObject(forKey: "LCCertificatePassword")
        }
    }

    /// `+[NSUserDefaults lcSharedDefaults]`: where the engine reads the marker.
    private static func engineSharedDefaults() -> UserDefaults {
        let selector = NSSelectorFromString("lcSharedDefaults")
        if UserDefaults.responds(to: selector),
           let defaults = UserDefaults.perform(selector)?.takeUnretainedValue() as? UserDefaults {
            return defaults
        }
        return .standard
    }
}
