@testable import DownloadCore
import XCTest

/// End-to-end tests against `LocalRangeServer`: real sockets, real URLSession, real disk.
final class RangeDownloaderTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() {
        files.forEach { try? FileManager.default.removeItem(at: $0) }
        files = []
        super.tearDown()
    }

    private func tempFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rd-\(UUID().uuidString).bin")
        files.append(url)
        return url
    }

    private func config(connections: Int, minSplit: Int64 = 256 * 1024) -> RangeDownloader.Configuration {
        var c = RangeDownloader.Configuration()
        c.connections = connections
        c.minSplitSize = minSplit
        c.requestTimeout = 15
        return c
    }

    func testProbeDetectsRangesSizeValidatorAndFilename() async throws {
        var options = LocalRangeServer.Options()
        options.contentDisposition = "attachment; filename=\"laporan.pdf\""
        let server = try LocalRangeServer(size: 300_000, options: options)
        let resource = try await ResourceProber.probe(RemoteRequest(url: server.url))
        XCTAssertTrue(resource.acceptsRanges)
        XCTAssertEqual(resource.totalBytes, 300_000)
        XCTAssertEqual(resource.validator, "\"v1\"")
        XCTAssertEqual(resource.suggestedFilename, "laporan.pdf")
    }

    func testParallelDownloadIsByteExactAndUsesSeparateConnections() async throws {
        var options = LocalRangeServer.Options()
        options.bytesPerSecond = 4 << 20 // per connection, so overlap is observable
        let server = try LocalRangeServer(size: 8 << 20, options: options)
        let resource = try await ResourceProber.probe(RemoteRequest(url: server.url))
        let file = tempFile()

        let downloader = RangeDownloader(request: RemoteRequest(url: server.url), resource: resource,
                                         fileURL: file, configuration: config(connections: 6))
        try await downloader.run()

        XCTAssertEqual(try Data(contentsOf: file), server.content)
        XCTAssertEqual(downloader.progress.downloadedBytes, Int64(8 << 20))
        XCTAssertGreaterThanOrEqual(server.snapshot().peakActive, 4,
                                    "range requests must run on separate concurrent connections")
    }

    func testPauseAndResumeContinuesWhereItStopped() async throws {
        var options = LocalRangeServer.Options()
        options.bytesPerSecond = 512 << 10
        let size = 6 << 20
        let server = try LocalRangeServer(size: size, options: options)
        let resource = try await ResourceProber.probe(RemoteRequest(url: server.url))
        let file = tempFile()

        let first = RangeDownloader(request: RemoteRequest(url: server.url), resource: resource,
                                    fileURL: file, configuration: config(connections: 4))
        let task = Task { try await first.run() }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "got \($0)") }

        let snapshot = first.snapshot()
        let done = snapshot.reduce(Int64(0)) { $0 + $1.downloaded }
        XCTAssertGreaterThan(done, 0)
        XCTAssertLessThan(done, Int64(size))
        XCTAssertTrue(SegmentPlanner.isValidTiling(snapshot, totalBytes: Int64(size)))

        let sentBeforeResume = server.snapshot().bodyBytesSent
        let second = RangeDownloader(request: RemoteRequest(url: server.url), resource: resource,
                                     fileURL: file, resumeFrom: snapshot, configuration: config(connections: 4))
        XCTAssertTrue(second.isResuming)
        try await second.run()

        XCTAssertEqual(try Data(contentsOf: file), server.content)
        let sentForResume = server.snapshot().bodyBytesSent - sentBeforeResume
        XCTAssertLessThan(sentForResume, size - Int(done) + (1 << 20),
                          "resume must only fetch the missing bytes (plus in-flight slack)")
    }

    func testThrottlingServerReducesConnectionsInsteadOfFailing() async throws {
        var options = LocalRangeServer.Options()
        options.maxConcurrent = 2
        options.bytesPerSecond = 4 << 20
        let server = try LocalRangeServer(size: 6 << 20, options: options)
        server.setMaxConcurrent(nil)
        let resource = try await ResourceProber.probe(RemoteRequest(url: server.url))
        server.setMaxConcurrent(2)
        let file = tempFile()

        let downloader = RangeDownloader(request: RemoteRequest(url: server.url), resource: resource,
                                         fileURL: file, configuration: config(connections: 8))
        try await downloader.run()

        XCTAssertEqual(try Data(contentsOf: file), server.content)
        XCTAssertGreaterThan(server.snapshot().throttled, 0, "server should have pushed back with 429")
        XCTAssertLessThanOrEqual(server.snapshot().peakActive, 2)
    }

    func testConnectionsRampBackUpWhenServerRecovers() async throws {
        var options = LocalRangeServer.Options()
        options.bytesPerSecond = 1 << 20
        let server = try LocalRangeServer(size: 8 << 20, options: options)
        let resource = try await ResourceProber.probe(RemoteRequest(url: server.url))
        server.setMaxConcurrent(1)                       // overloaded at first…
        Task {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            server.setMaxConcurrent(nil)                 // …then recovers
        }

        var cfg = config(connections: 4)
        cfg.rampUpInterval = 0.3
        let file = tempFile()
        let downloader = RangeDownloader(request: RemoteRequest(url: server.url), resource: resource,
                                         fileURL: file, configuration: cfg)
        try await downloader.run()

        XCTAssertEqual(try Data(contentsOf: file), server.content)
        let stats = server.snapshot()
        XCTAssertGreaterThan(stats.throttled, 0)
        XCTAssertGreaterThanOrEqual(stats.peakActive, 3, "connections should be added back after the 429s stop")
    }

    /// Per-connection-capped link (like a single TCP flow over Starlink): auto-scaling must add connections.
    func testAutoScalingAddsConnectionsWhenEachIsSlow() async throws {
        var options = LocalRangeServer.Options()
        options.bytesPerSecond = 1 << 20
        let server = try LocalRangeServer(size: 40 << 20, options: options)
        let resource = try await ResourceProber.probe(RemoteRequest(url: server.url))

        var cfg = config(connections: 2)
        cfg.maxConnections = 16
        cfg.scaleInterval = 0.5
        let file = tempFile()
        let downloader = RangeDownloader(request: RemoteRequest(url: server.url), resource: resource,
                                         fileURL: file, configuration: cfg)
        try await downloader.run()

        XCTAssertEqual(try Data(contentsOf: file), server.content)
        XCTAssertGreaterThanOrEqual(server.snapshot().peakActive, 6, "should have scaled well beyond the initial 2")
    }

    func testRetiresConnectionsThatDoNotAddSpeed() async throws {
        let server = try LocalRangeServer(size: 64 << 20)  // loopback: no per-connection cap
        let resource = try await ResourceProber.probe(RemoteRequest(url: server.url))
        let scheduler = SegmentScheduler(segments: SegmentPlanner.plan(totalBytes: resource.totalBytes, acceptsRanges: true,
                                                                       connections: 4),
                                         workers: 4, minSplitSize: 1 << 20)
        scheduler.requestRetire(2)
        XCTAssertTrue(scheduler.consumeRetire())
        XCTAssertTrue(scheduler.consumeRetire())
        XCTAssertFalse(scheduler.consumeRetire(), "only the requested number retire")
        XCTAssertEqual(scheduler.activeWorkers, 2)
        _ = server
    }

    func testAutoScalingCanBeDisabled() async throws {
        var options = LocalRangeServer.Options()
        options.bytesPerSecond = 2 << 20
        let server = try LocalRangeServer(size: 8 << 20, options: options)
        let resource = try await ResourceProber.probe(RemoteRequest(url: server.url))
        var cfg = config(connections: 2)
        cfg.autoScale = false
        cfg.scaleInterval = 0.3
        let downloader = RangeDownloader(request: RemoteRequest(url: server.url), resource: resource,
                                         fileURL: tempFile(), configuration: cfg)
        try await downloader.run()
        XCTAssertLessThanOrEqual(server.snapshot().peakActive, 2)
    }

    func testServerWithoutRangeSupportFallsBackToSingleStream() async throws {
        var options = LocalRangeServer.Options()
        options.supportsRanges = false
        let server = try LocalRangeServer(size: 3 << 20, options: options)
        let resource = try await ResourceProber.probe(RemoteRequest(url: server.url))
        XCTAssertFalse(resource.acceptsRanges)
        XCTAssertEqual(resource.totalBytes, Int64(3 << 20))

        let file = tempFile()
        let downloader = RangeDownloader(request: RemoteRequest(url: server.url), resource: resource,
                                         fileURL: file, configuration: config(connections: 8))
        try await downloader.run()
        XCTAssertEqual(try Data(contentsOf: file), server.content)
        XCTAssertEqual(server.snapshot().peakActive, 1)
    }

    func testChangedRemoteFileIsDetectedOnResume() async throws {
        var options = LocalRangeServer.Options()
        options.bytesPerSecond = 1 << 20
        let server = try LocalRangeServer(size: 4 << 20, options: options)
        let resource = try await ResourceProber.probe(RemoteRequest(url: server.url))
        let file = tempFile()

        let first = RangeDownloader(request: RemoteRequest(url: server.url), resource: resource,
                                    fileURL: file, configuration: config(connections: 2))
        let task = Task { try await first.run() }
        try await Task.sleep(nanoseconds: 700_000_000)
        task.cancel()
        _ = await task.result

        server.setETag("\"v2\"") // the file was replaced on the server
        let second = RangeDownloader(request: RemoteRequest(url: server.url), resource: resource,
                                     fileURL: file, resumeFrom: first.snapshot(), configuration: config(connections: 2))
        do {
            try await second.run()
            XCTFail("resume must not splice two versions of a file")
        } catch let error as DownloadEngineError {
            XCTAssertEqual(error, .remoteChanged)
        }
    }

    func testMissingFileFailsWithoutRetryingForever() async throws {
        let server = try LocalRangeServer(size: 1000)
        let missing = RemoteRequest(url: URL(string: "http://127.0.0.1:1/nothing")!)
        _ = server
        do {
            _ = try await ResourceProber.probe(missing, timeout: 2, maxAttempts: 2)
            XCTFail("expected a connection error")
        } catch {
            XCTAssertTrue(error is URLError, "got \(error)")
        }
    }
}
