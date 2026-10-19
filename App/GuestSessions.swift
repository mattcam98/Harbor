import Foundation
import HarborCore
import Observation
import UIKit

/// The guests that are running beside Harbor, each in its own process.
///
/// Harbor's interface stays alive underneath. One guest at a time fills the
/// screen; the others keep running out of sight, and so does the one on
/// screen when the user goes back to Harbor.
@MainActor
@Observable
final class GuestSessions {
    struct Session: Identifiable, Equatable {
        /// The data container the guest runs with. One guest per container.
        let id: String
        let guest: GuestApp
    }

    private(set) var running: [Session] = []
    /// The session on screen, or `nil` when Harbor's own interface is.
    private(set) var visible: String?

    /// A guest could not start, or stopped with an error while starting.
    @ObservationIgnored var onFailure: ((GuestApp, String) -> Void)?

    @ObservationIgnored private var controllers: [String: HarborGuestSceneController] = [:]
    /// The most recent start, which the next one waits for.
    @ObservationIgnored private var starting: Task<Void, Never>?
    /// How long one guest is given to start before the next is begun.
    ///
    /// The extension is told which guest to run through its own settings,
    /// which every copy of it shares: it writes them, the engine reads them
    /// and clears them. Two copies started together overwrite each other and
    /// one of them finds nothing to run. That exchange takes a few
    /// thousandths of a second; this leaves a wide margin.
    private static let startSpacing = Duration.milliseconds(1500)
    @ObservationIgnored private let stage = GuestStage()

    /// Whether this copy of Harbor can run guests beside itself at all.
    static var isAvailable: Bool { HarborGuestSceneController.isAvailable }

    init() {
        stage.onReturn = { [weak self] in self?.showHarbor() }
        stage.menu = { [weak self] in self?.handleMenu() ?? [] }
    }

    func isRunning(_ guest: GuestApp) -> Bool {
        running.contains { $0.guest.folderName == guest.folderName }
    }

    /// Starts the guest, or brings it back if it is already running.
    func open(_ guest: GuestApp, container: String? = nil) throws {
        let id = container ?? guest.defaultContainer
        if controllers[id] != nil {
            show(id)
            return
        }

        let controller = HarborGuestSceneController(folderName: guest.folderName, container: id)
        controller.onFailed = { [weak self] reason in
            self?.ended(id)
            self?.onFailure?(guest, reason)
        }
        controller.onExited = { [weak self] in self?.ended(id) }

        try stage.add(controller)
        controllers[id] = controller
        running.append(Session(id: id, guest: guest))
        show(id)

        // One at a time. The view is in the window by now, which the scene
        // needs.
        let previous = starting
        starting = Task { [weak self, weak controller] in
            await previous?.value
            guard let self, let controller, self.controllers[id] === controller else { return }
            controller.start()
            try? await Task.sleep(for: Self.startSpacing)
        }
    }

    func show(_ id: String) {
        guard let controller = controllers[id] else { return }
        visible = id
        stage.show(controller)
    }

    /// Puts Harbor's own interface back on screen. Guests keep running.
    func showHarbor() {
        visible = nil
        stage.show(nil)
    }

    func close(_ id: String) {
        guard let controller = controllers[id] else { return }
        if visible == id {
            showHarbor()
        }
        // The session is removed when the process is gone.
        controller.terminate()
    }

    /// Hands a URL to a running guest and brings it forward.
    func open(_ url: String, in id: String) {
        controllers[id]?.openURL(url)
        show(id)
    }

    private func ended(_ id: String) {
        guard let controller = controllers.removeValue(forKey: id) else { return }
        running.removeAll { $0.id == id }
        if visible == id {
            visible = nil
            stage.show(nil)
        }
        stage.remove(controller)
    }

    /// What a long press on the return handle offers.
    private func handleMenu() -> [UIMenuElement] {
        var items: [UIMenuElement] = [
            UIAction(title: "Back to Harbor", image: UIImage(systemName: "square.grid.2x2")) { [weak self] _ in
                self?.showHarbor()
            },
        ]
        let others = running.filter { $0.id != visible }
        if !others.isEmpty {
            items.append(UIMenu(title: "Switch to", options: .displayInline, children: others.map { session in
                UIAction(title: session.guest.name, image: UIImage(systemName: "arrow.left.arrow.right")) { [weak self] _ in
                    self?.show(session.id)
                }
            }))
        }
        if let current = running.first(where: { $0.id == visible }) {
            items.append(UIAction(
                title: "Close \(current.guest.name)", image: UIImage(systemName: "xmark"), attributes: .destructive
            ) { [weak self] _ in
                self?.close(current.id)
            })
        }
        return items
    }
}
