import Foundation

/// The list of data containers that have a guest running in them.
///
/// LiveContainer's scene controller reports to a class of this name from
/// LiveContainer's own interface, which Harbor does not build. It is told
/// from whichever thread the extension machinery calls back on.
@objc(MultitaskManager)
final class MultitaskManager: NSObject {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var containers: Set<String> = []

    @objc(registerMultitaskContainerWithContainer:)
    static func register(container: String) {
        lock.withLock { _ = containers.insert(container) }
    }

    @objc(unregisterMultitaskContainerWithContainer:)
    static func unregister(container: String) {
        lock.withLock { _ = containers.remove(container) }
    }

    @objc(isUsingWithContainer:)
    static func isUsing(container: String) -> Bool {
        lock.withLock { containers.contains(container) }
    }
}
