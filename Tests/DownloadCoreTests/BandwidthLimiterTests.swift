@testable import DownloadCore
import XCTest

final class BandwidthLimiterTests: XCTestCase {
    func testUnlimitedNeverWaits() async throws {
        let limiter = BandwidthLimiter()
        let start = Date()
        for _ in 0..<100 { try await limiter.acquire(10 << 20) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
    }

    func testCapHoldsAcrossConcurrentCallers() async throws {
        let limiter = BandwidthLimiter(bytesPerSecond: 1 << 20, burst: 0.1)
        let start = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { for _ in 0..<4 { try await limiter.acquire(128 << 10) } }
            }
            try await group.waitForAll()
        }
        // 2 MB at 1 MB/s, minus the 0.1 s burst allowance.
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(elapsed, 1.7)
        XCTAssertLessThan(elapsed, 3.5)
    }

    func testRemovingTheCapReleasesWaiters() async throws {
        let limiter = BandwidthLimiter(bytesPerSecond: 100 << 10, burst: 0)
        let start = Date()
        let waiter = Task { try await limiter.acquire(10 << 20) } // would take ~100 s
        try await Task.sleep(nanoseconds: 300_000_000)
        limiter.setLimit(0)
        try await waiter.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertEqual(limiter.limit, 0)
    }

    func testDownloadRespectsLimitAndStaysByteExact() async throws {
        let server = try LocalRangeServer(size: 3 << 20)
        let resource = try await ResourceProber.probe(RemoteRequest(url: server.url))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bw-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: file) }

        var config = RangeDownloader.Configuration()
        config.connections = 4
        config.minSplitSize = 256 << 10
        config.autoScale = false
        config.limiter = BandwidthLimiter(bytesPerSecond: 1 << 20, burst: 0.1)
        let downloader = RangeDownloader(request: RemoteRequest(url: server.url), resource: resource,
                                         fileURL: file, configuration: config)
        let start = Date()
        try await downloader.run()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(try Data(contentsOf: file), server.content)
        // 3 MB at 1 MB/s; a loopback server unthrottled would finish in well under a second.
        XCTAssertGreaterThan(elapsed, 2.3, "limit was not applied")
        XCTAssertLessThan(elapsed, 6)
    }
}
