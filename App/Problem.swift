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
            self.init(title: "Sign in again", detail: "Your Apple ID session has expired.")
        case AccountError.noTeams:
            self.init(title: "No developer team", detail: "This Apple ID is not a member of any development team.")
        case InstallError.notAnApp:
            self.init(title: "Not an app", detail: "The file does not contain a single app in a Payload folder.")
        case InstallError.encrypted:
            self.init(
                title: "Encrypted app",
                detail: "This app is still encrypted by the App Store and cannot run when sideloaded. Use a decrypted copy.")
        case InstallError.reinstallRequired:
            self.init(
                title: "Install again",
                detail: "The certificate this app was signed with is no longer on your team. Install the app again to re-sign it.")
        case VerificationError.digestMismatch, VerificationError.sizeMismatch, VerificationError.digestMissing:
            self.init(
                title: "Download rejected",
                detail: "A downloaded file did not match what Harbor expects, so it was not used.")
        case LoopbackFileServer.Failure.couldNotStart(let reason):
            self.init(title: "Could not make the shortcut", detail: "Harbor could not hand the shortcut to iOS (\(reason)). Try again.")
        case is GuestStageError:
            self.init(title: "Could not open the app", detail: "Harbor has no window to show it in. Close Harbor and open it again.")
        case SourceListError.notASecureAddress:
            self.init(
                title: "Not a source address",
                detail: "Enter a web address that starts with https://. Harbor does not read sources over an unprotected connection.")
        case is DecodingError:
            self.init(
                title: "Not a source",
                detail: "That address did not return a list of apps in the format AltStore and SideStore use.")
        case DownloadError.notSecure(let host):
            self.init(
                title: "Download refused",
                detail: "The download would have gone over an unprotected connection (\(host)), so Harbor did not make it.")
        case DownloadError.status(let code):
            self.init(
                title: "Download failed",
                detail: code == 0
                    ? "The server did not send the file."
                    : "The server answered with error \(code). The file may have been moved or removed.")
        case DownloadError.tooLarge(let limit):
            self.init(
                title: "Download too large",
                detail: "The file is larger than \(limit.formatted(.byteCount(style: .file))), the most Harbor accepts here.")
        case let policy as ArchivePolicyError:
            self.init(title: "Unsafe archive", detail: "The archive was refused before unpacking (\(policy)).")
        case GuestLibraryError.encrypted:
            self.init(
                title: "Encrypted app",
                detail: "This app is still encrypted by the App Store and cannot run inside Harbor. Use a decrypted copy.")
        case GuestLibraryError.unsupportedArchitecture:
            self.init(title: "Cannot run this app", detail: "The app has no 64-bit ARM code.")
        case GuestLibraryError.notAnApp, GuestLibraryError.missingExecutable:
            self.init(title: "Not an app", detail: "The file does not contain a usable app.")
        case IdentityImportError.unreadable:
            self.init(
                title: "Certificate not imported",
                detail: "The password is wrong, or the file is not a certificate export Harbor can read.")
        case IdentityImportError.noPrivateKey:
            self.init(
                title: "Certificate not imported",
                detail: "The file has a certificate but not its private key. Export the identity, not just the certificate.")
        case AppModel.GuestError.certificateRequired:
            self.init(
                title: "Signing certificate needed",
                detail: "On this version of iOS an app can only run inside Harbor once it is signed. Import a signing certificate first.")
        case AppModel.GuestError.signatureRejected(let reason):
            self.init(
                title: "iOS rejected the signature",
                detail: "The app was signed, but iOS will not load it. iOS said: \(reason)")
        case IdentityImportError.expired(let date):
            self.init(
                title: "Certificate expired",
                detail: "This certificate expired on \(date.formatted(date: .abbreviated, time: .omitted)). Export the current one instead.")
        case IdentityImportError.notAcceptedByThisInstall(let accepted):
            self.init(
                title: "Wrong certificate",
                detail: "iOS only loads apps signed with a certificate this copy of Harbor was installed with. Export one of these instead:\n\(accepted.joined(separator: "\n"))")
        case EngineBridge.Failure.engineUnavailable(let what):
            self.init(title: "Container engine unavailable", detail: "Harbor could not reach its container engine (\(what)).")
        case SigningError.cancelled:
            self.init(title: "Cancelled", detail: "Nothing was changed.")
        default:
            self.init(title: "Something went wrong", detail: error.localizedDescription)
        }
    }

    private init(_ issue: DeviceIssue) {
        switch issue {
        case .vpnOff:
            self.init(title: "Turn on LocalDevVPN", detail: "Harbor reaches this device through the LocalDevVPN app. Connect it, then try again.")
        case .pairingMissing:
            self.init(title: "Import a pairing file", detail: "Harbor needs a pairing file made on a computer to install apps.")
        case .pairingRejected(let reason):
            self.init(title: "Pairing file not accepted", detail: "Make a new pairing file on a computer and import it. (\(reason))")
        case .deviceUnreachable(let reason):
            self.init(title: "Device not reachable", detail: "The VPN is on but the device did not answer. Try again. (\(reason))")
        case .failed(let reason):
            self.init(title: "Device operation failed", detail: reason)
        }
    }

    private init(_ feasibility: InstallFeasibility) {
        switch feasibility {
        case .blockedByActiveAppLimit(_, let limit):
            self.init(
                title: "App limit reached",
                detail: "A free Apple ID can have \(limit) sideloaded apps active at once, Harbor included. Remove one first.")
        case .blockedByAppIDLimit(let needed, let available, let nextSlot):
            let when = nextSlot.map { " The next one frees up \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""
            self.init(
                title: "App ID limit reached",
                detail: "This app needs \(needed) App IDs and \(available) are free. A free Apple ID gets 10 per week.\(when)")
        case .allowed:
            self.init(title: "Something went wrong", detail: "The install was refused unexpectedly.")
        }
    }
}
