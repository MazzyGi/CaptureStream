import Foundation

public struct Size: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

/// 有界帧队列（规范 §23）：满时按策略丢弃，绝不无限积压。
public final class BoundedFrameQueue<T>: @unchecked Sendable {
    public enum OverflowPolicy: Sendable {
        case dropOldest   // 低延迟推荐
        case dropNewest
        case block
    }

    private var items: [T] = []
    private let capacity: Int
    private let policy: OverflowPolicy
    private let lock = NSCondition()
    public private(set) var droppedCount = 0
    public private(set) var overflowCount = 0

    public init(capacity: Int, policy: OverflowPolicy = .dropOldest) {
        precondition(capacity >= 1, "capacity must be >= 1")
        self.capacity = capacity
        self.policy = policy
    }

    /// 入队。dropOldest/dropNewest 立即返回；block 挂起等待空间。
    public func push(_ item: T) {
        lock.lock(); defer { lock.unlock() }
        switch policy {
        case .dropOldest:
            if items.count >= capacity {
                items.removeFirst()
                droppedCount += 1
                overflowCount += 1
            }
            items.append(item)
        case .dropNewest:
            if items.count >= capacity {
                droppedCount += 1
                overflowCount += 1
                return
            }
            items.append(item)
        case .block:
            while items.count >= capacity {
                lock.wait()
            }
            items.append(item)
        }
        lock.signal()
    }

    /// 出队（空则挂起）。timeout 秒后返回 nil。
    public func pop(timeout: Double? = nil) -> T? {
        lock.lock(); defer { lock.unlock() }
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while items.isEmpty {
            if let d = deadline, !lock.wait(until: d) { return nil }
            else if deadline == nil { lock.wait() }
        }
        let item = items.removeFirst()
        if items.count < capacity { lock.signal() }
        return item
    }

    /// 非阻塞取出。
    public func tryPop() -> T? {
        lock.lock(); defer { lock.unlock() }
        guard !items.isEmpty else { return nil }
        let item = items.removeFirst()
        if items.count < capacity { lock.signal() }
        return item
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return items.count
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        items.removeAll()
        lock.broadcast()
    }
}
