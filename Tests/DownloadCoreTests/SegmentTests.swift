@testable import DownloadCore
import XCTest

final class SegmentPlannerTests: XCTestCase {
    func testPlanTilesFileExactly() {
        for total: Int64 in [1, 1_000, 1 << 20, (8 << 20) + 7, 10_000_019] {
            for connections in [1, 3, 8, 16] {
                let plan = SegmentPlanner.plan(totalBytes: total, acceptsRanges: true,
                                               connections: connections, minSegmentSize: 256 * 1024)
                XCTAssertTrue(SegmentPlanner.isValidTiling(plan, totalBytes: total), "total \(total) conns \(connections)")
                XCTAssertLessThanOrEqual(plan.count, connections)
            }
        }
    }

    func testSmallFilesAndNoRangesUseOneSegment() {
        XCTAssertEqual(SegmentPlanner.plan(totalBytes: 100_000, acceptsRanges: true, connections: 8).count, 1)
        XCTAssertEqual(SegmentPlanner.plan(totalBytes: 50 << 20, acceptsRanges: false, connections: 8).count, 1)
        let unknown = SegmentPlanner.plan(totalBytes: -1, acceptsRanges: false, connections: 8)
        XCTAssertEqual(unknown, [SegmentState(start: 0, end: -1)])
    }

    func testEightConnectionsOnLargeFile() {
        let plan = SegmentPlanner.plan(totalBytes: 800 << 20, acceptsRanges: true, connections: 8)
        XCTAssertEqual(plan.count, 8)
        XCTAssertEqual(plan.map(\.length), Array(repeating: 100 << 20, count: 8))
    }

    func testTilingRejectsGapsAndOverlaps() {
        let gap = [SegmentState(start: 0, end: 9), SegmentState(start: 11, end: 19)]
        let overlap = [SegmentState(start: 0, end: 10), SegmentState(start: 10, end: 19)]
        let bad = [SegmentState(start: 0, end: 19, downloaded: 30)]
        XCTAssertFalse(SegmentPlanner.isValidTiling(gap, totalBytes: 20))
        XCTAssertFalse(SegmentPlanner.isValidTiling(overlap, totalBytes: 20))
        XCTAssertFalse(SegmentPlanner.isValidTiling(bad, totalBytes: 20))
    }
}

final class SegmentSchedulerTests: XCTestCase {
    private let mib: Int64 = 1 << 20

    func testClaimsUnassignedSegmentsFirst() {
        let plan = SegmentPlanner.plan(totalBytes: 8 * mib, acceptsRanges: true, connections: 4)
        let scheduler = SegmentScheduler(segments: plan, workers: 4, minSplitSize: mib)
        let claims = (0..<4).compactMap { _ in scheduler.claim() }
        XCTAssertEqual(claims.map(\.offset), [0, 2 * mib, 4 * mib, 6 * mib])
    }

    func testIdleWorkerStealsBackHalfOfLargestSegment() {
        let scheduler = SegmentScheduler(segments: [SegmentState(start: 0, end: 8 * mib - 1)],
                                         workers: 2, minSplitSize: mib)
        let first = scheduler.claim()!
        _ = scheduler.reserve(first.id, count: Int(2 * mib))
        scheduler.commit(first.id, length: Int(2 * mib))

        let stolen = scheduler.claim()!
        XCTAssertEqual(stolen.offset, 5 * mib)            // middle of the unreserved 6 MiB
        XCTAssertEqual(stolen.end, 8 * mib - 1)
        XCTAssertEqual(scheduler.end(of: first.id), 5 * mib - 1)

        // The original worker is now clamped at the new boundary.
        _ = scheduler.reserve(first.id, count: Int(2 * mib))
        let tail = scheduler.reserve(first.id, count: Int(2 * mib))
        XCTAssertEqual(tail.length, Int(mib))
        XCTAssertTrue(SegmentPlanner.isValidTiling(scheduler.snapshot(), totalBytes: 8 * mib))
    }

    func testNoStealBelowMinimumSplit() {
        let scheduler = SegmentScheduler(segments: [SegmentState(start: 0, end: mib - 1)],
                                         workers: 2, minSplitSize: mib)
        XCTAssertNotNil(scheduler.claim())
        XCTAssertNil(scheduler.claim()) // second worker exits instead of splitting 1 MiB
    }

    func testReleaseDiscardsUncommittedReservation() {
        let scheduler = SegmentScheduler(segments: [SegmentState(start: 0, end: 4 * mib - 1)],
                                         workers: 1, minSplitSize: mib)
        let claim = scheduler.claim()!
        _ = scheduler.reserve(claim.id, count: 1000)
        scheduler.commit(claim.id, length: 1000)
        _ = scheduler.reserve(claim.id, count: 5000) // never written
        scheduler.release(claim.id)

        let again = scheduler.claim()!
        XCTAssertEqual(again.offset, 1000)
        XCTAssertEqual(scheduler.snapshot().first?.downloaded, 1000)
    }

    func testThrottledWorkerYieldsOnlyWhenOthersRemain() {
        let plan = SegmentPlanner.plan(totalBytes: 4 * mib, acceptsRanges: true, connections: 2)
        let scheduler = SegmentScheduler(segments: plan, workers: 2, minSplitSize: mib)
        let a = scheduler.claim()!
        let b = scheduler.claim()!
        XCTAssertTrue(scheduler.releaseAndYield(a.id))   // b is still running
        XCTAssertFalse(scheduler.releaseAndYield(b.id))  // last worker must retry itself
    }
}

final class FileSinkTests: XCTestCase {
    func testConcurrentOffsetWritesProduceExactFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sink-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        let size = 4 << 20
        let expected = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let sink = try FileSink(url: url, expectedSize: Int64(size), truncate: true)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.intValue, size, "preallocated + ftruncated")

        let chunk = 64 * 1024
        try await withThrowingTaskGroup(of: Void.self) { group in
            for start in stride(from: 0, to: size, by: chunk).reversed() { // deliberately out of order
                group.addTask {
                    let piece = expected.subdata(in: start..<min(size, start + chunk))
                    try sink.write(piece, count: piece.count, at: Int64(start))
                }
            }
            try await group.waitForAll()
        }
        try sink.synchronize()
        sink.close()
        XCTAssertEqual(try Data(contentsOf: url), expected)
    }

    func testRefusesWhenDiskTooSmall() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("huge-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try FileSink(url: url, expectedSize: 1 << 60, truncate: true)) { error in
            guard case .insufficientSpace = error as? DownloadEngineError else {
                return XCTFail("expected insufficientSpace, got \(error)")
            }
        }
    }
}
