@testable import DownloadCore
import XCTest

final class AutoScalerTests: XCTestCase {
    func testGrowsWhileThroughputImprovesThenStops() {
        var s = ConnectionAutoScaler(initial: 8, maxConnections: 32)
        XCTAssertEqual(s.evaluate(throughput: 10, canAdd: true), 0)   // warm-up ignored
        XCTAssertEqual(s.evaluate(throughput: 30, canAdd: true), 4)   // baseline 30 → 12
        XCTAssertEqual(s.evaluate(throughput: 31, canAdd: true), 0)   // settling
        XCTAssertEqual(s.evaluate(throughput: 42, canAdd: true), 6)   // +40 % → 18
        XCTAssertEqual(s.evaluate(throughput: 40, canAdd: true), 0)   // settling
        XCTAssertEqual(s.evaluate(throughput: 43, canAdd: true), -6)  // +2 % → plateau, give the step back
        XCTAssertEqual(s.phase, .done)
        XCTAssertEqual(s.target, 12)
        XCTAssertEqual(s.evaluate(throughput: 99, canAdd: true), 0)   // stays done
    }

    func testRespectsMaximumAndPushback() {
        var s = ConnectionAutoScaler(initial: 30, maxConnections: 32)
        _ = s.evaluate(throughput: 1, canAdd: true)
        XCTAssertEqual(s.evaluate(throughput: 10, canAdd: true), 2)
        XCTAssertEqual(s.target, 32)

        var pushed = ConnectionAutoScaler(initial: 8, maxConnections: 32)
        _ = pushed.evaluate(throughput: 1, canAdd: true)
        pushed.serverPushedBack()
        XCTAssertEqual(pushed.evaluate(throughput: 10, canAdd: true), 0)

        var blocked = ConnectionAutoScaler(initial: 8, maxConnections: 32)
        _ = blocked.evaluate(throughput: 1, canAdd: true)
        XCTAssertEqual(blocked.evaluate(throughput: 10, canAdd: false), 0, "no work to hand out → don't add")
    }

    func testSaturatedLinkReturnsToBaseline() {
        // Link already full at 8 connections (e.g. 200 Mbit/s cap): extra ones are retired.
        var s = ConnectionAutoScaler(initial: 8, maxConnections: 32)
        _ = s.evaluate(throughput: 25, canAdd: true)
        XCTAssertEqual(s.evaluate(throughput: 25, canAdd: true), 4)
        _ = s.evaluate(throughput: 25, canAdd: true)
        XCTAssertEqual(s.evaluate(throughput: 25.5, canAdd: true), -4)
        XCTAssertEqual(s.target, 8)
    }
}
