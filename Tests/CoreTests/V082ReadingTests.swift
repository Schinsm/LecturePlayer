import Foundation
import Testing
@testable import Core
@Suite struct V082ReadingTests {
    @Test func indexedActiveUnitsKeepOrderAndOriginalSpanMapping() throws {
        let t=try SubtitleParser.parse(Data("WEBVTT\n\na\n00:00.000 --> 00:01.000\nSpeaker 0: cash flows\n\nb\n00:01.100 --> 00:02.000\nSpeaker 0: are not profits.\n\nc\n00:05.000 --> 00:06.000\nNext topic.\n".utf8),format:"vtt")
        let index=ReadingIndex(t.cues)
        #expect(index.units.count==2)
        #expect(index.unitID(for:t.cues[1].id)==index.units[0].id)
        #expect(index.activeUnits(t.cues.reversed().map(\.id)).map(\.id)==index.units.map(\.id))
        #expect(index.activeUnits([]).isEmpty)
        let text=index.units[0].content(translations:[:],mode:"英文",hideSpeakers:true)
        #expect(text.spans.map(\.cueID)==Array(t.cues.prefix(2)).map(\.id))
        #expect(text.text.contains("cash flows are not profits."))
        #expect(ReadingIndex(t.cues,grouped:false).units.count==3)
    }
    @Test func longLectureIndexHotPathBenchmark() throws {
        let text="WEBVTT\n\n"+(0..<2000).map {n in "\(n)\n\(String(format:"%02d:%02d.000",n/60,n%60)) --> \(String(format:"%02d:%02d.900",n/60,n%60))\nSpeaker 0: The cash flow is not the same as accounting profit.\n"}.joined(separator:"\n")
        let t=try SubtitleParser.parse(Data(text.utf8),format:"vtt")
        let start=Date();let index=ReadingIndex(t.cues);let build=Date().timeIntervalSince(start)
        let lookup=Date()
        for n in 0..<10000 {_=index.activeUnits([t.cues[n%2000].id]);_=index.unitID(for:t.cues[n%2000].id)}
        let hot=Date().timeIntervalSince(lookup)
        let old=Date();for _ in 0..<10 {_=ReadingUnits.make(t.cues)}
        print("LP082_PERF index_build_seconds=\(build) indexed_10000_seconds=\(hot) repeated_10_builds_seconds=\(Date().timeIntervalSince(old))")
        #expect(index.units.count==2000)
    }
}
