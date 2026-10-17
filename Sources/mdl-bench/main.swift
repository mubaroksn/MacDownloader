import DownloadCore
import Foundation

// Usage: mdl-bench <url> [--connections 1,8,16] [--seconds 10]
// Measures throughput and CPU cost of the RangeDownloader engine for a fixed time window.

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
    let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    return user + sys
}

let args = CommandLine.arguments
guard args.count >= 2, let url = URL(string: args[1]) else {
    print("usage: mdl-bench <url> [--connections 1,8,16] [--seconds 10]")
    exit(2)
}
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
    return args[i + 1]
}
let connectionList = (option("--connections") ?? "1,4,8,16,32").split(separator: ",").compactMap { Int($0) }
let seconds = Double(option("--seconds") ?? "10") ?? 10

let resolved = try await DownloadResolver.resolve(RemoteRequest(url: url), timeout: 20, maxAttempts: 2)
let r = resolved.resource
print("PROBE host=\(r.finalURL.host ?? "?") ranges=\(r.acceptsRanges) size=\(r.totalBytes) type=\(r.contentType ?? "-")")

for connections in connectionList {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString).bin")
    var config = RangeDownloader.Configuration()
    config.connections = connections
    let downloader = RangeDownloader(request: resolved.request, resource: r, fileURL: file, configuration: config)

    let cpuStart = cpuSeconds()
    let start = Date()
    let task = Task { try await downloader.run() }
    var peak = 0.0
    var last: Int64 = 0
    var lastTime = start
    var maxConnections = 0
    while Date().timeIntervalSince(start) < seconds {
        try await Task.sleep(nanoseconds: 500_000_000)
        let p = downloader.progress
        let now = Date()
        peak = max(peak, Double(p.downloadedBytes - last) / now.timeIntervalSince(lastTime))
        last = p.downloadedBytes
        lastTime = now
        maxConnections = max(maxConnections, p.activeConnections)
        if p.totalBytes > 0 && p.downloadedBytes >= p.totalBytes { break }
    }
    task.cancel()
    _ = await task.result
    let elapsed = Date().timeIntervalSince(start)
    let bytes = downloader.progress.downloadedBytes
    let cpu = cpuSeconds() - cpuStart
    let mbps = Double(bytes) * 8 / elapsed / 1e6
    let cpuPerGB = bytes > 0 ? cpu / (Double(bytes) / 1e9) : 0
    print(String(format: "RESULT conns=%d active=%d avg=%.0fMbps (%.1fMB/s) peak=%.0fMbps cpu=%.2fs cpu/GB=%.2fs",
                 connections, maxConnections, mbps, mbps / 8, peak * 8 / 1e6, cpu, cpuPerGB))
    try? FileManager.default.removeItem(at: file)
}
