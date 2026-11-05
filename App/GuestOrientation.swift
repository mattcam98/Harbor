import UIKit

/// Which way Harbor's window may turn.
///
/// A guest is drawn inside Harbor's window, so it turns when Harbor turns,
/// and only then. Left to Harbor's own answer every guest would be turned
/// sideways with the phone, including a phone app that never is: a video
/// app keeps its player page upright and goes full screen by itself when
/// the phone is turned. Laid out sideways anyway, such an app comes out
/// broken. So while a guest is on screen Harbor turns only as far as the
/// guest says its interface can, as iOS does for the app itself, and
/// follows it when that changes (the player going full screen, and back).
@MainActor
enum GuestOrientation {
    /// What Harbor's window allows now. `HarborAppDelegate` answers iOS
    /// with it.
    private(set) static var allowed: UIInterfaceOrientationMask = harbor

    /// What Harbor's own interface allows, as its Info.plist says.
    static var harbor: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    /// Follows the guest on screen, or Harbor's own interface for `nil`.
    ///
    /// - Parameter guest: what the guest supports, empty until it has said.
    static func follow(_ guest: UIInterfaceOrientationMask?) {
        let mask = allowed(for: guest, harbor: harbor)
        guard mask != allowed else { return }
        allowed = mask

        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            // Turned a way that is no longer allowed: turn now. Otherwise iOS
            // turns the window by itself when the phone is next turned, or
            // straight away if it is already held a newly allowed way.
            if !mask.contains(Self.mask(for: scene.interfaceOrientation)) {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
            }
        }
    }

    /// What Harbor's window allows for a guest that supports `guest`. An
    /// answer with nothing in common with Harbor's own would stop the app,
    /// so that, or a guest that has not said yet, leaves Harbor's.
    nonisolated static func allowed(
        for guest: UIInterfaceOrientationMask?,
        harbor: UIInterfaceOrientationMask
    ) -> UIInterfaceOrientationMask {
        guard let guest else { return harbor }
        let both = guest.intersection(harbor)
        return both.isEmpty ? harbor : both
    }

    private static func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: []
        }
    }
}
