import Foundation

// One gate for all bridge traffic, matching gptk's concurrency preset, so the
// membership prefetch, the library pager and user actions never stampede Google
actor RPCLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Bool, Never>)] = []
    private var nextWaiterID: UInt64 = 0

    init(limit: Int = 3) {
        self.limit = limit
    }

    // Throws CancellationError without ever having taken a slot; a normal return
    // always owns a slot the caller must release
    func acquire() async throws {
        try Task.checkCancellation()
        if running < limit {
            running += 1
            return
        }
        let id = nextWaiterID
        nextWaiterID += 1
        let gotSlot = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        guard gotSlot else { throw CancellationError() }
    }

    func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            // the slot transfers to the next waiter; running stays constant
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}
