import XCTest
@testable import CaptureStreamCore

/// 跨线程计数辅助（测试用）。
final class CounterBox {
    private let l = NSLock()
    private var v = 0
    var value: Int {
        get { l.lock(); defer { l.unlock() }; return v }
        set { l.lock(); defer { l.unlock() }; v = newValue }
    }
}

final class QueueTests: XCTestCase {

    func testDropOldestKeepsNewest() {
        let q = BoundedFrameQueue<Int>(capacity: 2, policy: .dropOldest)
        q.push(1); q.push(2); q.push(3)
        XCTAssertEqual(q.count, 2)
        XCTAssertEqual(q.tryPop(), 2)   // 1 被丢弃
        XCTAssertEqual(q.tryPop(), 3)
        XCTAssertEqual(q.droppedCount, 1)
    }

    func testDropNewestRejectsWhenFull() {
        let q = BoundedFrameQueue<Int>(capacity: 2, policy: .dropNewest)
        q.push(1); q.push(2); q.push(3)
        XCTAssertEqual(q.tryPop(), 1)
        XCTAssertEqual(q.tryPop(), 2)
        XCTAssertNil(q.tryPop())
        XCTAssertEqual(q.droppedCount, 1)
    }

    func testBlockingQueuePopsAll() {
        let q = BoundedFrameQueue<Int>(capacity: 4, policy: .block)
        q.push(1); q.push(2)
        XCTAssertEqual(q.tryPop(), 1)
        XCTAssertEqual(q.tryPop(), 2)
    }

    func testPopTimeoutReturnsNil() {
        let q = BoundedFrameQueue<Int>(capacity: 2)
        XCTAssertNil(q.pop(timeout: 0.05))
    }

    func testConcurrentProducerConsumer() {
        let q = BoundedFrameQueue<Int>(capacity: 3, policy: .dropOldest)
        let n = 10_000
        let done = DispatchSemaphore(value: 0)
        let got = CounterBox()
        let producerDone = CounterBox()
        Thread.detachNewThread {
            for i in 0..<n { q.push(i) }
            producerDone.value = 1
            done.signal()
        }
        Thread.detachNewThread {
            // 消费到生产结束且队列排空为止（dropOldest 下部分帧被丢弃是预期行为）
            while true {
                if q.pop(timeout: 0.2) != nil { got.value += 1 }
                else if producerDone.value == 1 { break }
            }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(done.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(got.value + q.droppedCount, n, "consumed \(got.value) + dropped \(q.droppedCount) must equal produced \(n)")
    }

    func testClearWakesBlockedPush() {
        let q = BoundedFrameQueue<Int>(capacity: 1, policy: .block)
        q.push(1)
        let pushed = expectation(description: "pushed")
        Thread.detachNewThread {
            q.push(2)   // blocks until clear()
            pushed.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)
        q.clear()
        wait(for: [pushed], timeout: 2)
    }
}

final class SettingsTests: XCTestCase {

    func testDefaultRoundTripPersistence() throws {
        var s = AppSettings()
        s.lastDeviceID = "test-device"
        s.scalingMode = .pixelPerfect
        s.audioDelayMs = 250
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cs-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try SettingsStore.export(s, to: url)
        let loaded = try SettingsStore.importSettings(from: url)
        XCTAssertEqual(loaded, s)
    }

    func testCodableStability() throws {
        let s = AppSettings()
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(back, s)
    }

    func testLatencyModeQueueSuggestions() {
        XCTAssertEqual(LatencyMode.ultraLow.recommendedQueueCapacity, 1)
        XCTAssertEqual(LatencyMode.quality.recommendedQueueCapacity, 4)
        XCTAssertEqual(LatencyMode.lowLatency.recommendedPolicy, .dropOldest)
    }

    func testFormatDescriptorLabel() {
        let f = CaptureFormatDescriptor(width: 1920, height: 1080, fps: 60, pixelFormat: "NV12")
        XCTAssertEqual(f.label, "1920×1080 @ 60 FPS · NV12")
    }
}

final class FPSCounterTests: XCTestCase {

    func testStageCounterFPS() {
        let c = StageCounter(window: 1.0)
        for i in 0..<60 { c.record(Double(i) / 60.0) }
        XCTAssertEqual(c.fps, 60, accuracy: 1.5)
    }

    func testStageCounterEmpty() {
        let c = StageCounter()
        XCTAssertEqual(c.fps, 0)
        XCTAssertEqual(c.count, 0)
    }

    func testStageCounterSingle() {
        let c = StageCounter()
        c.record(1.0)
        // 单样本回退为计数值 1（窗口内看到 1 个事件）
        XCTAssertEqual(c.fps, 1.0)
    }

    func testWindowPruning() {
        let c = StageCounter(window: 0.5)
        for i in 0..<100 { c.record(Double(i) * 0.01) }   // 10s 跨度
        XCTAssertLessThan(c.count, 100)   // 旧时间戳被修剪
        XCTAssertEqual(c.fps, 100, accuracy: 30)
    }
}
