/// Holds an async stub until the test explicitly releases it, including after cancellation.
actor TestGate {
    private var continuation: CheckedContinuation<Void,Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true; continuation?.resume(); continuation = nil
    }
}
