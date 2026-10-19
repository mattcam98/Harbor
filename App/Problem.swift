import Foundation
import HarborCore
import HarborPlatform
import HarborSigning
import SideSign

/// A failure as shown to the user: what went wrong and the one thing to do.
struct Problem: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var detail: String

    static func == (lhs: Problem, rhs: Problem) -> Bool {
        lhs.title == rhs.title && lhs.detail == rhs.detail
    }

    init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    init(_ error: any Error) {
        switch error {
        case let issue as DeviceIssue:
            self = Problem(issue)
        case ProvisioningError.blocked(let feasibility):
            self = Problem(feasibility)
        case AccountError.signInRequired:
            self.init(title: "Sign in again", detail: "Your Apple ID session has ended. Sign in from Settings.")
        case AccountError.machineIdentityRefused:
            self.init(
                title: "Apple isn't accepting sign-ins right now",
                detail: "This isn't a problem with your Apple ID or password. Try again later, or renew with Harbor Setup on a Mac.")
        case HostRenewal.Failure.installedForAnotherTeam:
            self.init(
                title: "Can't renew this copy",
                detail: "This copy of Harbor was installed by Xcode or with a different Apple ID. Sign in with the Apple ID Harbor Setup used, or renew from a Mac.")
        case AppModel.RenewalError.certificateGone:
            self.init(
                title: "Reinstall Harbor from a Mac",
                detail: "The certificate Harbor was signed with is no longer on your Apple ID. Run Harbor Setup again. Your apps and their data stay.")
        case AppModel.RenewalError.notSigned:
            self.init(title: "Nothing to renew", detail: "This copy of Harbor has no provisioning profile.")
        case AppModel.RenewalError.notExtended(let name):
            self.init(
                title: "Renewal didn't take",
                detail: "Apple answered, but \(name)'s expiry date didn't move. Try again in a few minutes.")
        case DeveloperPortalError.incorrectCredentials, ServerError.underlyingError(code: -20101, _):
            self.init(title: "Wrong Apple ID or password", detail: "Check them and try again.")
        case DeveloperPortalError.appSpecificPasswordRequired:
            self.init(
                title: "Use your Apple ID password",
                detail: "Apple asked for an app-specific password. Sign in with your normal Apple ID password instead.")
        case DeveloperPortalError.maximumAppIDLimitReached:
            self.init(title: "Weekly limit reached", detail: "A free Apple ID can register 10 App IDs a week. Try again in a few days.")
        case ServerError.underlyingError(_, let message):
            self.init(title: "Apple didn't accept that", detail: message)
        case ServerError.badServerResponse, ServerError.invalidResponseFormat, ServerError.missingKey:
            self.init(title: "Apple didn't answer as expected", detail: "Try again in a few minutes.")
        case AnisetteError.badServerResponse, AnisetteError.allServersFailed, ServerAnisette.Failure.noServers:
            self.init(
                title: "Sign-in service unavailable",
                detail: "Harbor couldn't reach the service it uses to sign in to Apple. Try again in a few minutes.")
        case AccountError.noTeams:
            self.init(title: "No developer team", detail: "This Apple ID isn't part of a development team.")
        case InstallError.notAnApp:
            self.init(title: "Not an app", detail: "This file doesn't contain an app.")
        case InstallError.encrypted, GuestLibraryError.encrypted:
            self.init(title: "App is encrypted", detail: "Apps from the App Store can't be sideloaded. Use a decrypted copy.")
        case InstallError.reinstallRequired:
            self.init(
                title: "Install again",
                detail: "The certificate this app was signed with is gone. Install the app again to sign it.")
        case VerificationError.digestMismatch, VerificationError.sizeMismatch, VerificationError.digestMissing:
            self.init(title: "Download rejected", detail: "The file didn't match what was expected, so it wasn't used.")
        case LoopbackFileServer.Failure.couldNotStart(let reason):
            self.init(title: "Couldn't make the icon", detail: "Try again. (\(reason))")
        case is GuestStageError:
            self.init(title: "Couldn't open the app", detail: "Close Harbor and open it again.")
        case is PairingError:
            self.init(title: "Pairing file not valid", detail: "Make a new one with Harbor Setup on a Mac.")
        case SourceListError.notASecureAddress:
            self.init(title: "Address not secure", detail: "Enter an address that starts with https://.")
        case is DecodingError:
            self.init(title: "Not a source", detail: "That address doesn't list apps in a format Harbor can read.")
        case DownloadError.notSecure:
            self.init(title: "Download blocked", detail: "The download wasn't over a secure connection.")
        case DownloadError.status(let code):
            self.init(
                title: "Download failed",
                detail: code == 0 ? "The server didn't send the file." : "The server returned error \(code). The file may have moved.")
        case DownloadError.tooLarge(let limit):
            self.init(
                title: "File too large",
                detail: "Harbor accepts files up to \(limit.formatted(.byteCount(style: .file))).")
        case let policy as ArchivePolicyError:
            self.init(title: "Unsafe file", detail: "Harbor didn't unpack this file. (\(policy))")
        case GuestLibraryError.unsupportedArchitecture:
            self.init(title: "Can't run this app", detail: "It isn't built for iPhone.")
        case GuestLibraryError.notAnApp, GuestLibraryError.missingExecutable:
            self.init(title: "Not an app", detail: "This file doesn't contain an app Harbor can use.")
        case IdentityImportError.unreadable:
            self.init(title: "Couldn't import", detail: "The password is wrong, or this isn't a certificate file.")
        case IdentityImportError.noPrivateKey:
            self.init(
                title: "Couldn't import",
                detail: "The file is missing its private key. Export the certificate together with its key.")
        case AppModel.GuestError.certificateRequired:
            self.init(
                title: "Certificate needed",
                detail: "Add a signing certificate in Settings to open apps inside Harbor.")
        case AppModel.GuestError.signatureRejected(let reason):
            self.init(title: "iOS rejected the app", detail: "It was signed, but iOS won't open it: \(reason)")
        case IdentityImportError.expired(let date):
            self.init(title: "Certificate expired", detail: "It expired on \(date.day). Export a current one.")
        case IdentityImportError.notAcceptedByThisInstall(let accepted):
            self.init(
                title: "Wrong certificate",
                detail: "Use the certificate Harbor was installed with:\n\(accepted.joined(separator: "\n"))")
        case EngineBridge.Failure.engineUnavailable(let what):
            self.init(title: "Something went wrong", detail: "Close Harbor and open it again. (\(what))")
        case SigningError.cancelled:
            self.init(title: "Cancelled", detail: "Nothing was changed.")
        default:
            self.init(title: "Something went wrong", detail: error.localizedDescription)
        }
    }

    private init(_ issue: DeviceIssue) {
        switch issue {
        case .vpnOff:
            self.init(title: "Turn on LocalDevVPN", detail: "Harbor needs LocalDevVPN connected to reach this iPhone.")
        case .pairingMissing:
            self.init(
                title: "Pair this iPhone",
                detail: PhonePairing.isSupported
                    ? "Harbor isn't paired with this iPhone yet. Go to Settings › Pair This iPhone."
                    : "Harbor needs a pairing file. Harbor Setup on a Mac makes one.")
        case .pairingRejected(let reason):
            self.init(
                title: "Pairing not accepted",
                detail: PhonePairing.isSupported
                    ? "Pair again in Settings. (\(reason))"
                    : "Run Harbor Setup on a Mac to make a new pairing file. (\(reason))")
        case .deviceUnreachable(let reason):
            self.init(title: "iPhone not responding", detail: "Check LocalDevVPN is connected, then try again. (\(reason))")
        case .failed(let reason):
            self.init(title: "Something went wrong", detail: reason)
        }
    }

    private init(_ feasibility: InstallFeasibility) {
        switch feasibility {
        case .blockedByActiveAppLimit(_, let limit):
            self.init(
                title: "App limit reached",
                detail: "A free Apple ID allows \(limit) sideloaded apps, Harbor included. Remove one first, or add the app inside Harbor instead.")
        case .blockedByAppIDLimit(let needed, let available, let nextSlot):
            let when = nextSlot.map { " You can register more from \($0.dayAndTime(midSentence: true))." } ?? ""
            let left = available == 0 ? "none are left" : available == 1 ? "1 is left" : "\(available) are left"
            self.init(
                title: "Weekly limit reached",
                detail: "This app needs \(needed == 1 ? "an App ID" : "\(needed) App IDs") and \(left). A free Apple ID gets 10 a week.\(when)")
        case .allowed:
            self.init(title: "Something went wrong", detail: "The install was refused.")
        }
    }
}
