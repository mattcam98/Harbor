/// Wraps a secret so it cannot reach a log by accident.
///
/// `print`, string interpolation, `debugPrint` and `dump` all show a
/// placeholder. The value is only reachable through `expose()`, which makes
/// every use easy to find in review.
public struct Redacted<Value: Sendable>: Sendable {
    private let value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public func expose() -> Value { value }
}

extension Redacted: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
