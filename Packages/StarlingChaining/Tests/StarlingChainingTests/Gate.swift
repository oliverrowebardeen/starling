import Foundation

/// Holds callers at one point until the test opens it, and lets the test
/// wait until a given number of callers have arrived. Deterministic: no
/// sleeps, no timing.
actor Gate {
    private var held: [CheckedContinuation<Void, Never>] = []
    private var arrivals = 0
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var isOpen = false

    func pass() async {
        arrivals += 1
        let ready = watchers.filter { $0.count <= arrivals }
        watchers.removeAll { $0.count <= arrivals }
        for watcher in ready { watcher.continuation.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { held.append($0) }
    }

    /// Returns once `count` callers have reached `pass()`.
    func arrived(_ count: Int = 1) async {
        guard arrivals < count else { return }
        await withCheckedContinuation { watchers.append((count, $0)) }
    }

    /// Lets everyone through from now on.
    func open() {
        isOpen = true
        for continuation in held { continuation.resume() }
        held = []
    }
}
