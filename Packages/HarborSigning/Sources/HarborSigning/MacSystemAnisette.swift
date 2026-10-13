#if os(macOS)
import Foundation
import SideSign

/// Anisette from macOS itself: this Mac's own machine identity, as the
/// system makes it for Apple's own apps.
///
/// Why this exists. Apple's sign-in decides whether to talk to a client
/// from the machine identity in the request, before it looks at the account.
/// From 12 October 2026 it refuses identities made by the emulated
/// provisioning libraries that on-device anisette and every anisette server
/// use (error -80045), and still accepts a real Mac's. Measured on
/// 13 October 2026 with one request each for an Apple ID that cannot exist:
/// emulated identity, -80045; this Mac's identity, an answer about the
/// account. `LiveAppleProbeTests` repeats the measurement.
///
/// The one-time password comes from AOSKit and the device's description from
/// AuthKit. Both are private system frameworks, and this is how AltServer
/// for Mac has always obtained anisette. Only a Mac can do it: on iOS the
/// same calls need entitlements a sideloaded app cannot have.
public struct MacSystemAnisette: AnisetteProviding {
    public enum Failure: Error, Equatable, Sendable {
        /// The system frameworks are missing, or no longer answer this way.
        case unavailable(String)
    }

    public init() {}

    public func anisetteData() async throws -> AnisetteData {
        for framework in ["AuthKit", "AOSKit"] {
            let path = "/System/Library/PrivateFrameworks/\(framework).framework/\(framework)"
            guard dlopen(path, RTLD_NOW) != nil else {
                throw Failure.unavailable("\(framework) could not be loaded")
            }
        }
        guard
            let utilities = NSClassFromString("AOSUtilities") as? NSObject.Type,
            utilities.responds(to: Self.oneTimePasswordSelector),
            let headers = utilities.perform(Self.oneTimePasswordSelector, with: "-2")?
                .takeUnretainedValue() as? [String: Any],
            let machineID = headers["X-Apple-MD-M"] as? String,
            let oneTimePassword = headers["X-Apple-MD"] as? String
        else {
            throw Failure.unavailable("macOS did not give a one-time password")
        }
        guard
            let deviceClass = NSClassFromString("AKDevice") as? NSObject.Type,
            let device = deviceClass.perform(NSSelectorFromString("currentDevice"))?
                .takeUnretainedValue() as? NSObject
        else {
            throw Failure.unavailable("macOS did not describe this device")
        }
        func text(_ name: String) throws -> String {
            let selector = NSSelectorFromString(name)
            guard device.responds(to: selector),
                  let value = device.perform(selector)?.takeUnretainedValue()
            else {
                throw Failure.unavailable("macOS did not give \(name)")
            }
            return String(describing: value)
        }

        return AnisetteData(
            machineID: machineID,
            oneTimePassword: oneTimePassword,
            localUserID: try text("localUserUUID"),
            routingInfo: "17106176",
            deviceID: try text("uniqueDeviceIdentifier"),
            serialNumber: try text("serialNumber"),
            // The system describes itself with no app named, because this
            // process is not one. Apple's own sign-in daemon is "akd".
            clientInfo: try text("serverFriendlyDescription")
                .replacingOccurrences(of: "((null)/1.0)", with: "(com.apple.akd/1.0)"),
            userAgent: "akd/1.0 CFNetwork/808.1.4",
            clientTime: ISO8601DateFormatter().string(from: Date()),
            locale: Locale.current.identifier,
            timeZone: TimeZone.current.abbreviation() ?? "UTC"
        )
    }

    private static let oneTimePasswordSelector = NSSelectorFromString("retrieveOTPHeadersForDSID:")
}
#endif
