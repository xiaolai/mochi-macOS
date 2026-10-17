import Foundation

/// A value a test reads after handing it to a `@Sendable` closure that may run in another task.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    public init(_ value: Value) { stored = value }
    public var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
