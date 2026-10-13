import Foundation
import SideSign

/// What to ask the user for during two-factor sign-in.
public enum VerificationPrompt: Equatable, Sendable {
    /// A code shown on the user's other Apple devices.
    case trustedDeviceCode(error: String?)
    /// A code sent by text message or phone call to this number.
    case phoneCode(number: String?, error: String?)
}

/// Turns SideSign's two-factor conversation into a single question for the
/// interface: "what is the code?".
public enum TwoFactor {
    /// Returns the code the user entered, or `nil` to cancel.
    public typealias CodeProvider = @Sendable (VerificationPrompt) async -> String?

    public static func handler(asking provideCode: @escaping CodeProvider) -> DeveloperPortal.VerificationHandler {
        { request in
            switch request {
            case .selectDeliveryMethod(let preferred, let phoneNumbers):
                // Follow Apple's preference; fall back to the first trusted number.
                if preferred != .trustedDevice, let phone = phoneNumbers.first {
                    return preferred == .voice ? .requestVoice(phoneID: phone.id) : .requestSMS(phoneID: phone.id)
                }
                return .requestTrustedDevice

            case .trustedDevice(let error):
                return response(await provideCode(.trustedDeviceCode(error: error)))

            case .sms(let phoneNumbers, let activeID, let error),
                 .voice(let phoneNumbers, let activeID, let error):
                let number = phoneNumbers.first { $0.id == activeID }?.number
                return response(await provideCode(.phoneCode(number: number, error: error)))
            }
        }
    }

    private static func response(_ code: String?) -> TwoFactorResponse {
        let digits = (code ?? "").filter(\.isNumber)
        return digits.isEmpty ? .cancel : .verificationCode(digits)
    }
}
