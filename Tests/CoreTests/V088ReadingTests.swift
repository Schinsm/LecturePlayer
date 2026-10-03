import Testing
@testable import Core

struct V088ReadingTests {
    let cues=[Cue(id:"a",start:1000,end:2000,en:"First."),Cue(id:"b",start:5000,end:7000,en:"Second."),Cue(id:"c",start:6000,end:8000,en:"Overlap.")]
    @Test func readerRetainsGapPositionWhileCaptionsAreEmpty() {
        let timeline=TranscriptTimeline(cues),mapper=SubtitleTimingMapper(offset:14)
        #expect(timeline.readingFocus(at:14,mapper:mapper).isEmpty)
        #expect(timeline.readingFocus(at:15,mapper:mapper)==["a"])
        #expect(timeline.readingFocus(at:18,mapper:mapper)==["a"])
        #expect(timeline.active(at:18,mapper:mapper).isEmpty)
        #expect(timeline.readingFocus(at:19,mapper:mapper)==["b"])
        #expect(timeline.readingFocus(at:20.5,mapper:mapper)==["b","c"])
        #expect(timeline.readingFocus(at:90,mapper:mapper)==["c"])
        #expect(timeline.active(at:90,mapper:mapper).isEmpty)
        // Backward seeks derive a fresh location, never the previous playback highlight.
        #expect(timeline.readingFocus(at:18,mapper:mapper)==["a"])
        #expect(timeline.readingFocus(at:0,mapper:mapper).isEmpty)
    }
    @Test func gapsMapIntoGroupedUnitsWithoutInventingTiming() {
        let cues=[Cue(id:"one",start:1000,end:1500,en:"Cash flow"),Cue(id:"two",start:1800,end:2300,en:"is negative.")]
        let index=ReadingIndex(cues, grouped:true)
        let timeline=TranscriptTimeline(cues),mapper=SubtitleTimingMapper()
        #expect(timeline.readingFocus(at:1.6,mapper:mapper)==["one"])
        #expect(timeline.active(at:1.6,mapper:mapper).isEmpty)
        #expect(index.unitID(for:"one")==index.unitID(for:"two"))
    }
}
