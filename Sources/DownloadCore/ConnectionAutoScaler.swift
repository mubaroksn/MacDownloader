import Foundation

/// Finds the connection count that saturates the link, per download.
///
/// Why: the best count depends on the path, not the file. On a datacenter link 8 connections
/// already saturate Google Drive (more is slower); on Starlink/LTE a single TCP flow is capped
/// by RTT and loss (~30-40 Mbit/s), so 200 Mbit/s needs 6+ flows. Instead of guessing, measure:
///
///   warm-up window (slow start, ignored) → baseline → add ~50 % more connections →
///   settle one window → measure → keep growing while throughput improves ≥ 10 %, else stop.
///
/// The scaler only proposes; the supervisor applies it when the scheduler has work to give and
/// the server hasn't pushed back recently (429/503 handling has priority).
struct ConnectionAutoScaler {
    enum Phase: Equatable {
        case warmingUp
        case measuring
        case settling(baseline: Double)
        case probing(baseline: Double)
        case done
    }

    let maxConnections: Int
    let minimumGain: Double
    private(set) var target: Int
    private(set) var phase: Phase = .warmingUp

    init(initial: Int, maxConnections: Int, minimumGain: Double = 0.10) {
        target = initial
        self.maxConnections = max(initial, maxConnections)
        self.minimumGain = minimumGain
    }

    /// Call once per window with the throughput measured over it (bytes/s).
    /// Returns how many connections to add now (0 = none).
    mutating func evaluate(throughput: Double, canAdd: Bool) -> Int {
        switch phase {
        case .done:
            return 0
        case .warmingUp:
            phase = .measuring
            return 0
        case .measuring:
            return grow(baseline: throughput, canAdd: canAdd)
        case .settling(let baseline):
            phase = .probing(baseline: baseline)
            return 0
        case .probing(let baseline):
            guard throughput >= baseline * (1 + minimumGain) else {
                phase = .done // plateau: more connections stopped helping
                return 0
            }
            return grow(baseline: throughput, canAdd: canAdd)
        }
    }

    /// The server pushed back: stop exploring upward for this download.
    mutating func serverPushedBack() { phase = .done }

    private mutating func grow(baseline: Double, canAdd: Bool) -> Int {
        guard canAdd, target < maxConnections, baseline > 0 else {
            phase = .done
            return 0
        }
        let step = min(maxConnections - target, max(2, target / 2))
        target += step
        phase = .settling(baseline: baseline)
        return step
    }
}
