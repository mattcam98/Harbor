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

    func add(_ guest: UIViewController) throws {
        try install()
        container.addChild(guest)
        guest.view.frame = container.view.bounds
        guest.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        guest.view.isHidden = true
        container.view.insertSubview(guest.view, belowSubview: container.handle)
        guest.didMove(toParent: container)
    }

    func remove(_ guest: UIViewController) {
        guest.willMove(toParent: nil)
        guest.view.removeFromSuperview()
        guest.removeFromParent()
    }

    /// Shows one guest, or none.
    func show(_ guest: UIViewController?) {
        for child in container.children {
            child.view.isHidden = child !== guest
        }
        container.view.isHidden = guest == nil
        if guest != nil {
            container.handle.wake()
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
        view.backgroundColor = .black

        // Seen only until the guest draws its first frame.
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        view.addSubview(handle)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        handle.place(in: view.bounds.inset(by: view.safeAreaInsets))
    }
}

/// The way back to Harbor from a guest: a small button that floats over the
/// guest at the edge of the screen.
///
/// iOS reserves its gestures for itself, so there is no swipe a guest could
/// not also want. A button the user can drag out of the way is the least
/// intrusive thing left. Tap goes back to Harbor; touch and hold offers the
/// other running apps and closing this one.
private final class ReturnHandle: UIButton {
    var onReturn: (() -> Void)?
    var menuProvider: (() -> [UIMenuElement])?

    private static let size: CGFloat = 44
    private static let restingAlpha: CGFloat = 0.45
    private var area = CGRect.zero
    private var dimming: Task<Void, Never>?

    /// Which edge, and how far down it, as a fraction of the height.
    private var onTrailingEdge: Bool
    private var fraction: CGFloat

    init() {
        let defaults = UserDefaults.standard
        onTrailingEdge = defaults.object(forKey: Self.edgeKey) as? Bool ?? true
        fraction = (defaults.object(forKey: Self.fractionKey) as? Double).map { CGFloat($0) } ?? 0.3
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))

        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = .glass()
        } else {
            configuration = .gray()
            configuration.background.visualEffect = UIBlurEffect(style: .systemThinMaterial)
        }
        configuration.image = UIImage(systemName: "square.grid.2x2.fill")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        configuration.cornerStyle = .capsule
        self.configuration = configuration
        accessibilityLabel = "Back to Harbor"
        accessibilityHint = "Touch and hold for other running apps."

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

    /// Keeps the handle inside `area`, at its remembered place.
    func place(in area: CGRect) {
        self.area = area
        guard area.width > Self.size, area.height > Self.size else { return }
        let margin: CGFloat = 6
        let x = onTrailingEdge ? area.maxX - Self.size - margin : area.minX + margin
        let travel = area.height - Self.size
        frame = CGRect(
            x: x, y: area.minY + min(max(fraction, 0), 1) * travel, width: Self.size, height: Self.size)
    }

    /// Full strength now, fading back after a few seconds of being left alone.
    func wake() {
        dimming?.cancel()
        alpha = 1
        dimming = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            UIView.animate(withDuration: 0.4) { self?.alpha = Self.restingAlpha }
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
            let travel = max(area.height - Self.size, 1)
            fraction = min(max((point.y - Self.size / 2 - area.minY) / travel, 0), 1)
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
