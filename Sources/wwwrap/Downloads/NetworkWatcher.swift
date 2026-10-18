import DownloadCore
import Foundation
import Network

/// Brings downloads back after the internet drops.
///
/// The engine already rides out short drops (each connection retries for about three
/// minutes). When a download still fails with a connection error, the manager marks it
/// `waitingForNetwork` and wakes this watcher, which resumes it as soon as the internet works.
///
/// Why probe instead of trusting `NWPathMonitor` alone: on Starlink (or any router whose
/// uplink dies) the Mac stays on Wi-Fi, so the path reads "satisfied" while nothing gets
/// through. The path monitor only tells us when to probe *sooner* (Wi-Fi came back); a
/// small HTTP request decides whether the internet is really back.
///
/// Cost: nothing while no download is waiting. While one is, one HEAD request every
/// 5–60 s (backing off while offline).
@MainActor
final class NetworkWatcher {
    static let shared = NetworkWatcher()

    private let monitor = NWPathMonitor()
    private var pathUp = true
    private var kicked = false
    private var loop: Task<Void, Never>?

    private init() {
        monitor.pathUpdateHandler = { path in
            let up = path.status == .satisfied
            Task { @MainActor in NetworkWatcher.shared.pathChanged(up) }
        }
        monitor.start(queue: DispatchQueue(label: "wwwrap.network")) // l10n-ignore
    }

    private func pathChanged(_ up: Bool) {
        if up && !pathUp { kicked = true } // Wi-Fi/Ethernet just came back: check right away
        pathUp = up
    }

    /// Starts watching if a download is waiting. Cheap to call repeatedly.
    func wake() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.run()
            self?.loop = nil
        }
    }

    private func run() async {
        var interval: TimeInterval = 5
        while DownloadManager.shared.hasDownloadsWaitingForNetwork {
            var waited: TimeInterval = 0
            while waited < interval && !kicked {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                waited += 1
            }
            kicked = false
            guard DownloadManager.shared.hasDownloadsWaitingForNetwork else { break }

            if pathUp, await Self.internetReachable() {
                DownloadManager.shared.resumeDownloadsWaitingForNetwork()
                interval = 5
            } else {
                interval = min(interval * 2, 60)
            }
        }
    }

    /// True when a well-known, tiny HTTPS endpoint answers at all.
    nonisolated static func internetReachable() async -> Bool {
        var request = URLRequest(url: URL(string: "https://captive.apple.com/hotspot-detect.html")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.httpMethod = "HEAD"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }
}

/// Which failures are worth an automatic retry once the network is back.
enum NetworkFailure {
    case connectivity   // no route, DNS, dropped or timed-out connection: retry indefinitely
    case server         // the server hiccuped (busy, cut the stream): retry a few times

    static func classify(_ error: Error) -> NetworkFailure? {
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
                 .callIsActive, .secureConnectionFailed, .cannotLoadFromNetwork:
                return .connectivity
            default:
                return nil
            }
        }
        if let engine = error as? DownloadEngineError {
            switch engine {
            case .prematureEnd, .throttled, .invalidResponse: return .server
            case .httpStatus(let code) where code >= 500 || code == 408: return .server
            default: return nil
            }
        }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, [50, 51, 54, 57, 60, 61, 64, 65].contains(ns.code) {
            return .connectivity // ENETDOWN, ENETUNREACH, ECONNRESET, ENOTCONN, ETIMEDOUT, ECONNREFUSED, EHOSTDOWN, EHOSTUNREACH
        }
        return nil
    }
}
