import Foundation
import Testing
@testable import Core

struct ReadingTests {
    @Test func gapAnchorDoesNotInventActiveCue() {
        let timeline = TranscriptTimeline([Cue(id: "a", start: 1000, end: 2000, en: "A"), Cue(id: "b", start: 5000, end: 6000, en: "B")])
        #expect(timeline.anchor(at: 0, offset: 0) == "a")
        #expect(timeline.anchor(at: 4, offset: 0) == "a")
        #expect(timeline.active(at: 4, offset: 0).isEmpty)
        #expect(timeline.anchor(at: 8, offset: 2) == "b")
        #expect(TranscriptTimeline([]).anchor(at: 4, offset: 0) == nil)
    }

    @Test func resumeClearsSearchWithoutDisablingFollow() {
        var state = ReadingState(); state.search("cash flow")
        #expect(!state.following); state.resume()
        #expect(state.following); #expect(state.query.isEmpty)
        state.browse(); #expect(!state.following); state.resume(); #expect(state.following)
    }
    @Test func indexedOverlapMatchesReferenceAcrossOffsets() throws {
        let cues = (0..<4000).map { Cue(id: "\($0)", start: $0 * 1800, end: $0 * 1800 + ($0 % 9 == 0 ? 10000 : 1000), en: "Text") }
        let timeline = TranscriptTimeline(cues)
        for offset in [-2.0, 0, 3] {
            for tickMS in stride(from: 0, through: 7_210_000, by: 1300) {
                let tick = Double(tickMS) / 1000
                let ms = tickMS - Int(offset * 1000)
                let expected = cues.filter { $0.start <= ms && $0.end > ms }.map(\.id)
                #expect(timeline.active(at: tick, offset: offset) == expected)
            }
        }
    }
}
