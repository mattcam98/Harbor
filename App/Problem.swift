import Foundation
import HarborCore
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
        case InstallError.reinstallRequired:
            self.init(
                title: "Install again",
                detail: "The certificate this app was signed with is no longer on your team. Install the app again to re-sign it.")
        case VerificationError.digestMismatch, VerificationError.sizeMismatch, VerificationError.digestMissing:
            self.init(
                title: "Download rejected",
                detail: "A downloaded file did not match what Harbor expects, so it was not used.")
        case let policy as ArchivePolicyError:
            self.init(title: "Unsafe archive", detail: "The archive was refused before unpacking (\(policy)).")
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
