import Foundation
import Testing
@testable import Core

struct V08CaptionTests {
    let cues = [Cue(id: "a", start: 1000, end: 3000, en: "First"), Cue(id: "b", start: 2000, end: 4000, en: "Second")]
    @Test func activeOnlyWithOffsetOverlapAndGap() {
        let timeline = TranscriptTimeline(cues), mapper = SubtitleTimingMapper(offset: 14)
        let translations = ["a": Translation(ai: "第一句", cacheKey: "k")]
        let ids = timeline.active(at: 16.5, mapper: mapper)
        let lines = VideoCaptionLine.make(cues: cues, activeIDs: ids, translations: translations, mode: "双语")
        #expect(lines.map(\.id) == ["a", "b"])
        #expect(lines[0].english == "First" && lines[0].chinese == "第一句")
        #expect(lines[1].english == "Second" && lines[1].chinese == nil)
        #expect(VideoCaptionLine.make(cues: cues, activeIDs: timeline.active(at: 18, mapper: mapper), translations: translations, mode: "双语").isEmpty)
        #expect(timeline.active(at: 14, mapper: mapper).isEmpty)
    }
    @Test func selectedTranslationAndLanguageFallback() {
        var edited = Translation(ai: "原译文", cacheKey: "k"); edited.edited = "人工校正"
        let ids = ["a", "b"]
        let chinese = VideoCaptionLine.make(cues: cues, activeIDs: ids, translations: ["a": edited], mode: "中文")
        #expect(chinese[0].english == nil && chinese[0].chinese == "人工校正")
        #expect(chinese[1].english == "Second")
        let english = VideoCaptionLine.make(cues: cues, activeIDs: ids, translations: ["a": edited], mode: "英文")
        #expect(english.allSatisfy {$0.chinese == nil})
        let other = VideoCaptionLine.make(cues: cues, activeIDs: ids, translations: ["a": Translation(ai: "另一个服务", cacheKey: "other")], mode: "双语")
        #expect(other[0].chinese == "另一个服务")
    }
    @Test func oldLessonDecodeAndIndependentPreferenceRoundTrip() throws {
        let c = Course(name: "Course")
        var lesson = Lecture(title: "Lesson", courseID: c.id, folderID: nil, url: URL(fileURLWithPath: "/tmp/example.mp4"), bookmark: nil, identity: "m")
        lesson.state.offset = 14; lesson.state.position = 4321; lesson.state.speed = 1.5; lesson.state.mode = "英文"
        let old = try Codec.decode(Lecture.self, Codec.encode(lesson))
        #expect(old.videoCaptions == nil && old.studyPanel == nil)
        var pref = VideoCaptionPreferences();pref.enabled = true;pref.mode = "中文";pref.fontSize = 26
        lesson.videoCaptions = pref; lesson.studyPanel = "chapters"
        let copy = try Codec.decode(Lecture.self, Codec.encode(lesson))
        #expect(copy.videoCaptions == pref && copy.studyPanel == "chapters")
        #expect(copy.state == old.state)
    }
}
