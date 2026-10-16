import Foundation

/// One recognised stretch of speech, in seconds from the start of the media.
public struct TimedText: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

/// Where a lesson's English subtitles came from, when the app produced them.
public enum TranscriptSource: String, Codable, Sendable {
    case appleSpeech = "macOS 转写", macWhisper = "MacWhisper"
}

/// Writes machine transcriptions as WebVTT into the course folder's `LecturePlayer/` export folder,
/// next to the translated subtitles. Source videos and subtitles are never touched, and the directory
/// scan skips that folder, so a transcription is never mistaken for new course material.
public enum TranscriptionOutput {
    public static func vtt(_ segments: [TimedText]) -> String {
        func stamp(_ seconds: Double) -> String {
            let ms = Int((max(0, seconds) * 1000).rounded())
            return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        var out = "WEBVTT\n\n"
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, segment.end > segment.start else { continue }
            out += "\(stamp(segment.start)) --> \(stamp(segment.end))\n\(text)\n\n"
        }
        return out
    }

    /// `<video folder>/LecturePlayer/<title>-<id>/transcript.en.vtt`, creating the export folder and its marker.
    public static func url(for lesson: Lecture) throws -> URL {
        guard let media = lesson.mediaSources.first(where: { $0.role == .screen }) ?? lesson.mediaSources.first else { throw Failure("无法确定课件视频所在目录") }
        let fm = FileManager.default
        let base = URL(fileURLWithPath: media.path).deletingLastPathComponent().appendingPathComponent("LecturePlayer", isDirectory: true)
        guard fm.fileExists(atPath: base.deletingLastPathComponent().path) else { throw StorageIssue(.unavailable) }
        if fm.fileExists(atPath: base.path) {
            guard (try base.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw StorageIssue(.conflict) }
            if !fm.fileExists(atPath: base.appendingPathComponent(GeneratedFiles.marker).path), !(try fm.contentsOfDirectory(atPath: base.path)).isEmpty { throw StorageIssue(.conflict) }
        }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try GeneratedFiles.ensureMarker(base.appendingPathComponent(GeneratedFiles.marker))
        let safe = String(lesson.title.map { "/:\\\n\r".contains($0) ? "_" : $0 }.prefix(70))
        let folder = base.appendingPathComponent("\(safe)-\(lesson.id.uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("transcript.en.vtt")
    }
}
