import Foundation
import os

/// Hands segments to workers and keeps every connection busy until the file is done.
///
/// All state lives behind one unfair lock; every operation is O(segments) at worst and
/// runs once per network chunk, so contention is negligible next to network and disk.
///
/// Two counters per segment make concurrent splitting safe:
/// - `reserved`: bytes a worker has claimed for writing (drives clamping and split points)
/// - `state.downloaded`: bytes confirmed on disk (the only value that is ever persisted)
final class SegmentScheduler: @unchecked Sendable {
    struct Claim: Sendable, Equatable {
        let id: Int
        let offset: Int64
        let end: Int64
    }

    private struct Slot {
        var state: SegmentState
        var reserved: Int64
        var assigned = false
    }

    private struct State {
        var slots: [Slot]
        var activeWorkers: Int
        var lastYield: Date?
        var retireRequests = 0
    }

    private let lock: OSAllocatedUnfairLock<State>
    private let minSplitSize: Int64

    init(segments: [SegmentState], workers: Int, minSplitSize: Int64) {
        let slots = segments.sorted { $0.start < $1.start }
            .map { Slot(state: $0, reserved: $0.downloaded) }
        lock = OSAllocatedUnfairLock(initialState: State(slots: slots, activeWorkers: workers))
        self.minSplitSize = max(64 * 1024, minSplitSize)
    }

    /// Next piece of work, or `nil` when the worker should exit (it is then no longer counted).
    ///
    /// Preference: an unassigned unfinished segment; otherwise steal the back half of the
    /// largest in-flight segment (IDM-style dynamic segmentation).
    func claim() -> Claim? {
        let minSplit = minSplitSize
        return lock.withLock { s in
            if let i = s.slots.indices.first(where: { !s.slots[$0].assigned && !s.slots[$0].state.isDone }) {
                s.slots[i].assigned = true
                s.slots[i].reserved = s.slots[i].state.downloaded
                return Claim(id: i, offset: s.slots[i].state.nextOffset, end: s.slots[i].state.end)
            }

            let candidates = s.slots.indices.filter { s.slots[$0].assigned && s.slots[$0].state.hasKnownLength }
            if let i = candidates.max(by: { Self.unreserved(s.slots[$0]) < Self.unreserved(s.slots[$1]) }),
               Self.unreserved(s.slots[i]) >= 2 * minSplit {
                let from = s.slots[i].state.start + s.slots[i].reserved
                let mid = from + Self.unreserved(s.slots[i]) / 2
                let stolen = SegmentState(start: mid, end: s.slots[i].state.end)
                s.slots[i].state.end = mid - 1
                s.slots.append(Slot(state: stolen, reserved: 0, assigned: true))
                return Claim(id: s.slots.count - 1, offset: mid, end: stolen.end)
            }

            s.activeWorkers -= 1
            return nil
        }
    }

    private static func unreserved(_ slot: Slot) -> Int64 {
        slot.state.hasKnownLength ? max(0, slot.state.length - slot.reserved) : 0
    }

    /// Current inclusive end of a segment (it shrinks when another worker steals from it).
    func end(of id: Int) -> Int64 {
        lock.withLock { $0.slots[id].state.end }
    }

    /// Reserves up to `count` bytes for writing and returns where to write them.
    /// The returned length is clamped to the segment end and may be zero.
    func reserve(_ id: Int, count: Int) -> (offset: Int64, length: Int) {
        lock.withLock { s in
            let slot = s.slots[id]
            let offset = slot.state.start + slot.reserved
            var length = Int64(count)
            if slot.state.hasKnownLength {
                length = max(0, min(length, slot.state.end - offset + 1))
            }
            s.slots[id].reserved += length
            return (offset, Int(length))
        }
    }

    /// Confirms `length` reserved bytes are on disk. Returns true when the segment is complete.
    @discardableResult
    func commit(_ id: Int, length: Int) -> Bool {
        lock.withLock { s in
            s.slots[id].state.downloaded += Int64(length)
            return s.slots[id].state.isDone
        }
    }

    /// Gives a segment back (finished, or after an error); unwritten reservations are discarded.
    /// `resetProgress` is for servers without range support: a retry restarts at byte 0.
    func release(_ id: Int, resetProgress: Bool = false) {
        lock.withLock { s in
            s.slots[id].assigned = false
            if resetProgress { s.slots[id].state.downloaded = 0 }
            s.slots[id].reserved = s.slots[id].state.downloaded
        }
    }

    /// Releases a throttled segment. Returns true when the worker should exit because other
    /// workers are still running (they will pick the segment up); false when it is the last
    /// worker and must retry itself after a backoff.
    func releaseAndYield(_ id: Int) -> Bool {
        lock.withLock { s in
            s.slots[id].assigned = false
            s.slots[id].reserved = s.slots[id].state.downloaded
            guard s.activeWorkers > 1 else { return false }
            s.activeWorkers -= 1
            s.lastYield = Date()
            return true
        }
    }

    var activeWorkers: Int { lock.withLock { $0.activeWorkers } }

    /// Asks `count` workers to leave at their next chunk boundary.
    func requestRetire(_ count: Int) {
        lock.withLock { $0.retireRequests += max(0, count) }
    }

    /// Called by a worker between chunks. True = this worker should stop now; it is then
    /// no longer counted, and its segment must be released (another worker continues it).
    func consumeRetire() -> Bool {
        lock.withLock { s in
            guard s.retireRequests > 0, s.activeWorkers > 1 else { return false }
            s.retireRequests -= 1
            s.activeWorkers -= 1
            return true
        }
    }

    func registerWorker() { lock.withLock { $0.activeWorkers += 1 } }

    /// Additive increase after a back-off: true when below target, nothing was refused for
    /// `quietPeriod`, and there is work a new connection could take (free or splittable).
    func shouldRampUp(target: Int, quietPeriod: TimeInterval) -> Bool {
        let minSplit = minSplitSize
        return lock.withLock { s in
            guard s.activeWorkers > 0, s.activeWorkers < target else { return false }
            if let last = s.lastYield, Date().timeIntervalSince(last) < quietPeriod { return false }
            return s.slots.contains { slot in
                (!slot.assigned && !slot.state.isDone)
                    || (slot.assigned && Self.unreserved(slot) >= 2 * minSplit)
            }
        }
    }

    func recentlyYielded(within period: TimeInterval) -> Bool {
        lock.withLock { s in s.lastYield.map { Date().timeIntervalSince($0) < period } ?? false }
    }

    /// True when another connection would have something to do and the server is quiet.
    func canScale(quietPeriod: TimeInterval) -> Bool {
        let minSplit = minSplitSize
        return lock.withLock { s in
            if let last = s.lastYield, Date().timeIntervalSince(last) < quietPeriod { return false }
            return s.slots.contains { slot in
                (!slot.assigned && !slot.state.isDone)
                    || (slot.assigned && Self.unreserved(slot) >= 2 * minSplit)
            }
        }
    }

    /// Marks the end of a stream whose length was unknown up front.
    func finishUnknownLength(_ id: Int) {
        lock.withLock { s in
            let state = s.slots[id].state
            s.slots[id].state.end = state.start + state.downloaded - 1
        }
    }

    func isDone(_ id: Int) -> Bool { lock.withLock { $0.slots[id].state.isDone } }

    var allDone: Bool { lock.withLock { $0.slots.allSatisfy { $0.state.isDone } } }

    var progress: (downloaded: Int64, connections: Int) {
        lock.withLock { s in
            (s.slots.reduce(0) { $0 + $1.state.downloaded }, s.slots.filter(\.assigned).count)
        }
    }

    /// Persistable view: committed bytes only, sorted by offset.
    func snapshot() -> [SegmentState] {
        lock.withLock { $0.slots.map(\.state).sorted { $0.start < $1.start } }
    }
}
