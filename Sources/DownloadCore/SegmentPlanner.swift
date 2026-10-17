import Foundation

public enum SegmentPlanner {
    /// Splits `totalBytes` into up to `connections` equal segments, never smaller than
    /// `minSegmentSize`. Unknown sizes and servers without range support get one segment.
    public static func plan(totalBytes: Int64,
                            acceptsRanges: Bool,
                            connections: Int,
                            minSegmentSize: Int64 = 1 << 20) -> [SegmentState] {
        guard acceptsRanges, totalBytes > 0 else {
            return [SegmentState(start: 0, end: totalBytes > 0 ? totalBytes - 1 : -1)]
        }
        let bySize = max(1, totalBytes / max(1, minSegmentSize))
        let count = max(1, min(Int64(max(1, connections)), bySize))
        let base = totalBytes / count
        let extra = totalBytes % count

        var segments: [SegmentState] = []
        segments.reserveCapacity(Int(count))
        var start: Int64 = 0
        for index in 0..<count {
            let length = base + (index < extra ? 1 : 0)
            segments.append(SegmentState(start: start, end: start + length - 1))
            start += length
        }
        return segments
    }

    /// True when `segments` tile `0..<totalBytes` exactly (sorted, no gaps, no overlap).
    /// Used to reject corrupt or foreign resume data.
    public static func isValidTiling(_ segments: [SegmentState], totalBytes: Int64) -> Bool {
        guard totalBytes > 0, !segments.isEmpty else { return false }
        var expected: Int64 = 0
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            guard segment.start == expected, segment.end >= segment.start,
                  segment.downloaded >= 0, segment.downloaded <= segment.length else { return false }
            expected = segment.end + 1
        }
        return expected == totalBytes
    }
}
