import UIKit

enum GuestStageError: Error {
    /// Harbor has no window to draw a guest in.
    case noWindow
}

/// Where running guests are drawn: a layer over Harbor's own interface,
/// in the same window.
///
/// A guest's view has to stay in a window for as long as it runs, so guests
/// that are not on screen are hidden here, not removed. When none is on
/// screen the whole layer is hidden and Harbor's interface shows through.
@MainActor
final class GuestStage {
    var onReturn: (() -> Void)? {
        get { container.handle.onReturn }
        set { container.handle.onReturn = newValue }
    }
    var menu: (() -> [UIMenuElement])? {
        get { container.handle.menuProvider }
        set { container.handle.menuProvider = newValue }
    }

    private let container = StageViewController()
    /// The guest on screen, if any.
    private weak var current: UIViewController?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        // Harbor is back without a link, from its own icon or the app
        // switcher: offer the way back for a moment. A link that arrives
        // with it, from a guest's Home Screen icon, takes it away again.
        observers.append(center.addObserver(
            forName: UIScene.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.current != nil else { return }
                self.container.handle.wake(after: .milliseconds(400))
            }
        })
        // Not in the picture iOS keeps for the app switcher.
        observers.append(center.addObserver(
            forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.container.handle.dismiss() }
        })
    }

    func add(_ guest: UIViewController, icon: UIImage?) throws {
        try install()
        container.addChild(guest)
        guest.view.frame = container.view.bounds
        guest.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        guest.view.isHidden = true
        // Seen until the guest draws its first frame, which covers it: the
        // app's icon, where iOS would show the app's launch screen.
        let placeholder = LaunchPlaceholder(icon: icon)
        placeholder.frame = guest.view.bounds
        placeholder.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        guest.view.insertSubview(placeholder, at: 0)
        container.view.insertSubview(guest.view, belowSubview: container.handle)
        guest.didMove(toParent: container)
    }

    func remove(_ guest: UIViewController) {
        guest.willMove(toParent: nil)
        guest.view.removeFromSuperview()
        guest.removeFromParent()
    }

    /// Shows one guest, or none.
    ///
    /// - Parameter offerReturn: whether to show the way back to Harbor for a
    ///   moment. Not for a guest opened from its own Home Screen icon: to
    ///   the user that is an app of its own, not something inside Harbor.
    func show(_ guest: UIViewController?, offerReturn: Bool = true, animated: Bool = true) {
        let stage = container.view!
        let wasShowing = current != nil
        current = guest
        let update = { [container] in
            for child in container.children {
                child.view.isHidden = child !== guest
            }
        }

        if guest != nil {
            if offerReturn {
                container.handle.wake()
            } else {
                container.handle.dismiss()
            }
            if !animated {
                update()
                stage.layer.removeAllAnimations()
                stage.alpha = 1
                stage.isHidden = false
            } else if wasShowing {
                // One app to another.
                UIView.transition(with: stage, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction], animations: update)
            } else {
                update()
                stage.alpha = 0
                stage.isHidden = false
                UIView.animate(withDuration: 0.2, delay: 0, options: .allowUserInteraction) { stage.alpha = 1 }
            }
        } else {
            container.handle.dismiss()
            guard wasShowing else {
                update()
                stage.isHidden = true
                return
            }
            UIView.animate(withDuration: 0.2, delay: 0, options: .allowUserInteraction) {
                stage.alpha = 0
            } completion: { [weak self] _ in
                // Unless a guest was shown again meanwhile.
                guard let self, self.current == nil else { return }
                update()
                stage.isHidden = true
                stage.alpha = 1
            }
        }
    }

    /// Puts the layer over the root of Harbor's window, once.
    private func install() throws {
        guard container.parent == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let root = (scene?.keyWindow ?? scene?.windows.first)?.rootViewController else {
            throw GuestStageError.noWindow
        }
        root.addChild(container)
        container.view.frame = root.view.bounds
        container.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.view.isHidden = true
        root.view.addSubview(container.view)
        container.didMove(toParent: root)
    }
}

private final class StageViewController: UIViewController {
    let handle = ReturnHandle()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.addSubview(handle)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        handle.place(in: view.bounds.inset(by: view.safeAreaInsets))
    }
}

/// An app's icon in the middle of a plain screen: what a guest looks like
/// while it starts, and what Harbor shows in its place while it gets ready
/// to start one (`LaunchCover`).
final class LaunchPlaceholder: UIView {
    static let iconSide: CGFloat = 100

    var icon: UIImage? {
        didSet {
            iconView.image = icon
            iconView.isHidden = icon == nil
        }
    }

    private let iconView = UIImageView()

    init(icon: UIImage?) {
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        iconView.contentMode = .scaleAspectFill
        iconView.clipsToBounds = true
        iconView.layer.cornerRadius = Self.iconSide * 0.2237
        iconView.layer.cornerCurve = .continuous
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSide),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSide),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        self.icon = icon
        iconView.image = icon
        iconView.isHidden = icon == nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }
}

/// The way back to Harbor from a guest, shown only for a moment: when the
/// guest is opened from Harbor, and when Harbor comes back to the front
/// with a guest on screen, as iOS shows a "back to" link in the status bar
/// when one app opens another. It then fades away entirely and the guest
/// has the whole screen.
///
/// iOS reserves its gestures for itself, so there is no swipe a guest could
/// not also want, and Harbor shares its Home Screen icon and its place in
/// the app switcher with the guests drawn in it. Something on screen is the
/// only way back that needs no trip to the Home Screen. Tap goes back to
/// Harbor; touch and hold offers the other running apps and closing this
/// one. The user can drag it to either edge.
private final class ReturnHandle: UIButton {
    var onReturn: (() -> Void)?
    var menuProvider: (() -> [UIMenuElement])?

    private static let height: CGFloat = 36
    /// How long it stays after it was last shown or touched.
    private static let shownFor = Duration.seconds(4)
    private var area = CGRect.zero
    private var dimming: Task<Void, Never>?

    /// Which edge, and how far down it, as a fraction of the height.
    private var onTrailingEdge: Bool
    private var fraction: CGFloat

    init() {
        let defaults = UserDefaults.standard
        onTrailingEdge = defaults.object(forKey: Self.edgeKey) as? Bool ?? true
        fraction = (defaults.object(forKey: Self.fractionKey) as? Double).map { CGFloat($0) } ?? 0.3
        super.init(frame: .zero)

        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = .glass()
        } else {
            configuration = .gray()
            configuration.background.visualEffect = UIBlurEffect(style: .systemThinMaterial)
        }
        configuration.image = UIImage(systemName: "chevron.backward")
        configuration.imagePadding = 4
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        var title = AttributedString("Harbor")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        configuration.attributedTitle = title
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 12)
        configuration.cornerStyle = .capsule
        self.configuration = configuration
        accessibilityLabel = "Back to Harbor"
        accessibilityHint = "Touch and hold for other running apps."
        alpha = 0

        addAction(UIAction { [weak self] _ in self?.onReturn?() }, for: .primaryActionTriggered)
        addAction(UIAction { [weak self] _ in self?.wake() }, for: .touchDown)
        menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.menuProvider?() ?? [])
            },
        ])
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    private var size: CGSize {
        let fitting = sizeThatFits(CGSize(width: 240, height: Self.height))
        return CGSize(width: ceil(fitting.width), height: max(Self.height, ceil(fitting.height)))
    }

    /// Keeps the handle inside `area`, at its remembered place.
    func place(in area: CGRect) {
        self.area = area
        let size = size
        guard area.width > size.width, area.height > size.height else { return }
        let margin: CGFloat = 8
        let x = onTrailingEdge ? area.maxX - size.width - margin : area.minX + margin
        let travel = area.height - size.height
        frame = CGRect(origin: CGPoint(x: x, y: area.minY + min(max(fraction, 0), 1) * travel), size: size)
    }

    /// Shows it now, or after `delay` unless something else decides first,
    /// and fades it away a few seconds later.
    func wake(after delay: Duration = .zero) {
        dimming?.cancel()
        dimming = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            // Taken away again before this got to run.
            guard !Task.isCancelled else { return }
            self?.appear()
            // Someone who cannot see it fade would lose it; it stays.
            guard !UIAccessibility.isVoiceOverRunning else { return }
            try? await Task.sleep(for: Self.shownFor)
            guard !Task.isCancelled else { return }
            self?.fade()
        }
    }

    /// Takes it away now.
    func dismiss() {
        dimming?.cancel()
        dimming = nil
        layer.removeAllAnimations()
        alpha = 0
        accessibilityElementsHidden = true
    }

    private func appear() {
        accessibilityElementsHidden = false
        UIView.animate(withDuration: 0.25, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.alpha = 1
        }
    }

    /// Fully: a view this transparent no longer takes touches, so the guest
    /// gets them.
    private func fade() {
        UIView.animate(withDuration: 0.6, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.alpha = 0
        } completion: { [weak self] finished in
            if finished { self?.accessibilityElementsHidden = true }
        }
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        wake()
        guard let superview else { return }
        let point = gesture.location(in: superview)
        switch gesture.state {
        case .changed:
            center = point
        case .ended, .cancelled, .failed:
            onTrailingEdge = point.x > area.midX
            let height = size.height
            let travel = max(area.height - height, 1)
            fraction = min(max((point.y - height / 2 - area.minY) / travel, 0), 1)
            UserDefaults.standard.set(onTrailingEdge, forKey: Self.edgeKey)
            UserDefaults.standard.set(Double(fraction), forKey: Self.fractionKey)
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
                self.place(in: self.area)
            }
        default:
            break
        }
    }

    private static let edgeKey = "HarborReturnHandleTrailing"
    private static let fractionKey = "HarborReturnHandleFraction"
}
