import Foundation
import Testing
@testable import Core

struct V081ReadingTests {
    func cue(_ id: String, _ text: String, _ start: Int, _ end: Int) -> Cue {Cue(id:id,start:start,end:end,en:text)}
    @Test func fragmentsSearchAndCharacterMappingPreserveSource() {
        let cues = [cue("a","Speaker 0: We discuss",0,1000),cue("b","Speaker 0: prospective analysis.",1100,2200),cue("c","Speaker 0: Next topic.",2200,3000)]
        let units = ReadingUnits.make(cues)
        #expect(units.count == 2)
        #expect(units[0].ids == ["a","b"])
        let text = units[0].content(translations:[:],mode:"英文")
        #expect(text.text == "We discuss prospective analysis.")
        #expect(text.cue(atUTF16:12) == "b")
        #expect(ReadingSearch.matches(units,translations:[:],query:"discuss prospective") == ["a","b"])
        #expect(units.flatMap(\.cues) == cues)
    }
    @Test func sentenceBoundariesAndLimits() {
        #expect(!ReadingUnits.sentenceEnds("Ask Dr."))
        #expect(!ReadingUnits.sentenceEnds("at 3.5"))
        #expect(ReadingUnits.sentenceEnds("complete.\""))
        let cues = [cue("a","Speaker 0: first",0,1000),cue("b","Speaker 1: second",1000,2000),cue("c","Speaker 1: third",1900,3000),cue("d","Speaker 1: fourth",3901,5000)]
        #expect(ReadingUnits.make(cues).count == 4)
        let many = (0..<10).map {cue("\($0)","part",$0*1000,($0+1)*1000)}
        #expect(ReadingUnits.make(many).map { $0.cues.count } == [8,2])
        #expect(ReadingUnits.make(many,video:true).map { $0.cues.count } == [3,3,3,1])
    }
    @Test func labelsOnlyAtLineStartAndTranslationEdits() {
        #expect(SpeakerLabel.clean("Speaker 12： Hello\n演讲者 3: 世界") == "Hello\n世界")
        #expect(SpeakerLabel.clean("The speaker 12: is mentioned") == "The speaker 12: is mentioned")
        let c = cue("a","Speaker 0: example",0,1000)
        var t = Translation(ai:"演讲者 0: 旧译文",cacheKey:"k");t.edited="说话人 0：人工校正"
        #expect(ReadingUnits.make([c])[0].content(translations:["a":t],mode:"中文").text == "人工校正")
    }
    @Test func oldPreferenceDecodeAndSourceExport() throws {
        let old = try JSONDecoder().decode(VideoCaptionPreferences.self,from:Data(#"{"enabled":true,"mode":"英文","fontSize":22}"#.utf8))
        #expect(old.position == nil && old.grouped == nil)
        let original = Data("WEBVTT\n\na\n00:00:00.000 --> 00:00:01.000\nSpeaker 0: hello\n\nb\n00:00:01.000 --> 00:00:02.000\nSpeaker 0: world.\n".utf8)
        let t = try SubtitleParser.parse(original,format:"vtt")
        let exported = try Exporter.render(t,kind:.englishVTT,hideSpeakers:true)
        let copy = try SubtitleParser.parse(exported,format:"vtt")
        #expect(copy.cues.map(\.start) == t.cues.map(\.start))
        #expect(copy.cues.map(\.sourceID) == t.cues.map(\.sourceID))
        #expect(copy.cues[0].en == "hello")
        #expect(t.original == original)
        #expect(String(decoding:try Exporter.render(t,kind:.text,hideSpeakers:true,grouped:true),as:UTF8.self) == "hello world.")
    }
}
