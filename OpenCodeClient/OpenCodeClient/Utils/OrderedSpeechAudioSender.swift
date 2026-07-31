import Foundation

nonisolated final class OrderedSpeechAudioSender: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private let sendChunk: @Sendable (Data) async -> Void
    private var queue: [Data] = []
    private var acceptsChunks = true
    private var workWaiter: CheckedContinuation<Void, Never>?
    private var worker: Task<Void, Never>?
    private var observedMaximum = 0

    init(
        capacity: Int = 32,
        sendChunk: @escaping @Sendable (Data) async -> Void
    ) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.sendChunk = sendChunk
        worker = Task { [weak self] in
            await self?.run()
        }
    }

    @discardableResult
    func enqueue(_ chunk: Data) -> Bool {
        condition.lock()
        while acceptsChunks, queue.count >= capacity {
            condition.wait()
        }
        guard acceptsChunks else {
            condition.unlock()
            return false
        }
        queue.append(chunk)
        observedMaximum = max(observedMaximum, queue.count)
        let waiter = workWaiter
        workWaiter = nil
        condition.unlock()
        waiter?.resume()
        return true
    }

    func finishAndDrain() async {
        let waiter = stopAccepting()
        waiter?.resume()
        if let worker {
            await worker.value
        }
    }

    var maximumBufferedCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return observedMaximum
    }

    private func run() async {
        while let chunk = await nextChunk() {
            await sendChunk(chunk)
        }
    }

    private func nextChunk() async -> Data? {
        while true {
            switch dequeue() {
            case .chunk(let chunk):
                return chunk
            case .finished:
                return nil
            case .wait:
                await withCheckedContinuation { continuation in
                    registerWaiter(continuation)
                }
            }
        }
    }

    private enum DequeueResult {
        case chunk(Data)
        case finished
        case wait
    }

    private func stopAccepting() -> CheckedContinuation<Void, Never>? {
        condition.lock()
        defer { condition.unlock() }
        acceptsChunks = false
        let waiter = workWaiter
        workWaiter = nil
        condition.broadcast()
        return waiter
    }

    private func dequeue() -> DequeueResult {
        condition.lock()
        defer { condition.unlock() }
        if !queue.isEmpty {
            let chunk = queue.removeFirst()
            condition.broadcast()
            return .chunk(chunk)
        }
        return acceptsChunks ? .wait : .finished
    }

    private func registerWaiter(_ continuation: CheckedContinuation<Void, Never>) {
        condition.lock()
        if !queue.isEmpty || !acceptsChunks {
            condition.unlock()
            continuation.resume()
        } else {
            workWaiter = continuation
            condition.unlock()
        }
    }
}
