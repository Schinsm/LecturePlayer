import Foundation

/// Prefix maximum ends allow overlap-aware queries without scanning all earlier cues.
public struct TranscriptTimeline: Sendable {
    private let cues: [Cue]
    private let maximumEnds: [Int]

    public init(_ input: [Cue]) {
        cues = input.enumerated().sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
        var maximum = 0
        maximumEnds = cues.map { maximum = max(maximum, $0.end); return maximum }
    }

    /// In a subtitle gap, keep the nearest preceding cue visible without highlighting it.
    public func anchor(at seconds: Double, offset: Double) -> String? {
        anchor(at: seconds, mapper: SubtitleTimingMapper(offset: offset))
    }
    public func anchor(at seconds: Double, mapper: SubtitleTimingMapper) -> String? {
        guard let milliseconds = mapper.originalMilliseconds(at: seconds) else { return nil }
        var low = 0, high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if Double(cues[middle].start) <= milliseconds { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? cues[low - 1].id : cues.first?.id
    }

    public func active(at seconds: Double, offset: Double) -> [String] {
        active(at: seconds, mapper: SubtitleTimingMapper(offset: offset))
    }
    public func active(at seconds: Double, mapper: SubtitleTimingMapper) -> [String] {
        guard let ms = mapper.originalMilliseconds(at: seconds), ms >= 0 else { return [] }
        var low = 0, high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if Double(cues[middle].start) <= ms { low = middle + 1 } else { high = middle }
        }
        let end = low
        low = 0; high = end
        while low < high {
            let middle = (low + high) / 2
            if Double(maximumEnds[middle]) <= ms { low = middle + 1 } else { high = middle }
        }
        return cues[low..<end].filter { Double($0.end) > ms }.map(\.id)
    }
}

public struct ReadingState: Equatable, Sendable {
    public private(set) var query = ""
    public private(set) var following = true
    public init() {}
    public mutating func search(_ value: String) { query = value; following = false }
    public mutating func browse() { following = false }
    public mutating func resume() { query = ""; following = true }
}
