import Foundation

/// All subtitle timing uses this mapping. Positive offsets delay subtitles.
/// Original cue timestamps and exported timestamps remain untouched.
public struct SubtitleTimingMapper: Equatable, Sendable {
    public let subtitleOffsetSeconds: Double
    public init(offset: Double = 0) { subtitleOffsetSeconds = offset.isFinite ? offset : 0 }
    public func effectiveTime(milliseconds: Int) -> Double { Double(milliseconds) / 1000 + subtitleOffsetSeconds }
    public func seekTarget(_ cue: Cue) -> Double { max(0, effectiveTime(milliseconds: cue.start)) }
    public func originalMilliseconds(at playbackSeconds: Double) -> Double? {
        guard playbackSeconds.isFinite else { return nil }
        let value = (playbackSeconds - subtitleOffsetSeconds) * 1000
        guard value.isFinite else { return nil }
        // Remove binary floating-point noise at exact millisecond boundaries, not real fractions.
        let nearest = value.rounded()
        return abs(value - nearest) < 0.000001 ? nearest : value
    }
    public var label: String {
        if abs(subtitleOffsetSeconds) < 0.0005 { return "已同步" }
        return String(format: "%+.3f", locale: Locale(identifier: "en_US_POSIX"), subtitleOffsetSeconds).replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression) + "s"
    }
}
