import Foundation
import Testing
@testable import Core

struct SubtitleSyncTests {
    let cue = Cue(id: "a", start: 1037099, end: 1038101, en: "Text")
    @Test func parserRetainsMilliseconds() throws {
        #expect(try SubtitleParser.timestamp("00:17:17.099") == 1037099)
        #expect(try SubtitleParser.timestamp("17:17.099") == 1037099)
        #expect(try SubtitleParser.timestamp("01:45:00,001") == 6300001)
        #expect(try SubtitleParser.timestamp("00:00.009") == 9)
    }
    @Test func parserPreservesStartEndAndOriginalBytes() throws {
        let original = Data("WEBVTT\n\noriginal\n00:17:17.099 --> 00:17:18.101\nText\n".utf8)
        let t = try SubtitleParser.parse(original, format: "vtt")
        #expect(t.cues[0].start == cue.start); #expect(t.cues[0].end == cue.end)
        #expect(t.original == original); #expect(t.cues[0].sourceID == "original")
    }
    @Test func malformedAndOverflowTimestampsRejected() {
        for value in ["00:01.+12", "00:01.12", "00:00:60.000", "99999999999999:00:00.000", "00:00.１２３"] {
            #expect(throws: (any Error).self) { try SubtitleParser.timestamp(value) }
        }
    }
    @Test func positiveOffsetDelaysCue() {
        let mapper = SubtitleTimingMapper(offset: 2)
        #expect(abs(mapper.seekTarget(cue)-1039.099) < 1e-9)
        #expect(TranscriptTimeline([cue]).active(at: 1037.5, mapper: mapper).isEmpty)
        #expect(TranscriptTimeline([cue]).active(at: 1039.5, mapper: mapper) == [cue.id])
    }
    @Test func negativeOffsetAdvancesCueAndClampsSeek() {
        let mapper = SubtitleTimingMapper(offset: -2)
        #expect(abs(mapper.seekTarget(cue)-1035.099) < 1e-9)
        #expect(TranscriptTimeline([cue]).active(at: 1035.5, mapper: mapper) == [cue.id])
        #expect(mapper.seekTarget(Cue(id: "zero", start: 1000, end: 2000, en: "A")) == 0)
    }
    @Test func resetRestoresOriginalTime() {
        var state = PlaybackState(); state.subtitleOffsetSeconds = 14; state.subtitleOffsetSeconds = 0
        #expect(state.timingMapper.seekTarget(cue) == Double(cue.start)/1000)
        #expect(state.timingMapper.label == "已同步")
    }
    @Test func exactStartIncludedEndExcludedAfterFloatingRoundTrip() {
        for offset in [0.0, 0.1, -0.1, 14] {
            let mapper = SubtitleTimingMapper(offset: offset); let timeline = TranscriptTimeline([cue])
            #expect(timeline.active(at: mapper.effectiveTime(milliseconds: cue.start), mapper: mapper) == [cue.id])
            #expect(timeline.active(at: mapper.effectiveTime(milliseconds: cue.end), mapper: mapper).isEmpty)
            #expect(timeline.active(at: mapper.seekTarget(cue)-0.00001, mapper: mapper).isEmpty)
        }
    }
    @Test func introPresetMapsFourteenSecondsWithoutEditingCues() {
        let mapper = SubtitleTimingMapper(offset: 14)
        #expect(abs(mapper.seekTarget(cue) - 1051.099) < 1e-9)
        #expect(cue.start == 1037099)
    }
    @Test func followAnchorRefreshesAndManualBrowseRemainsStopped() {
        let second = Cue(id: "b", start: 1038099, end: 1039101, en: "Second")
        let timeline = TranscriptTimeline([cue,second]); var state = ReadingState()
        #expect(timeline.anchor(at: 1038.5, mapper: .init()) == "b")
        #expect(timeline.anchor(at: 1038.5, mapper: .init(offset: 1)) == "a")
        #expect(state.following); state.browse()
        #expect(!state.following); state.resume(); #expect(state.following)
    }
    @Test func oldOffsetKeyRemainsCompatible() throws {
        let old = Data(#"{"position":90,"speed":1.5,"mode":"双语","offset":2.5}"#.utf8)
        let restored = try Codec.decode(PlaybackState.self, old)
        #expect(restored.subtitleOffsetSeconds == 2.5); #expect(restored.speed == 1.5)
        let again = try Codec.decode(PlaybackState.self, Codec.encode(restored)); #expect(again == restored)
    }
}

struct ModelCatalogTests {
    @Test func catalogExactlyMatchesRequestedModels() {
        #expect(TranslationModelCatalog.models.map(\.id) == ["gpt-5.6-luna","gpt-4o-mini","gpt-5.6-terra","gpt-5.6-sol"])
        #expect(TranslationModelCatalog.models.allSatisfy { $0.defaultReasoning == .none })
        #expect(ReasoningEffort.allCases.map(\.rawValue) == ["none","low","medium","high","xhigh","max"])
    }
    @Test func modelAndReasoningPreferencesPersist() throws {
        let name = "LecturePlayer-test-\(UUID())"; let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(TranslationPreferences.load(defaults).model == "gpt-5.6-luna")
        #expect(TranslationPreferences.load(defaults).effort == "none")
        defaults.set("gpt-5.6-terra", forKey: "model"); defaults.set("low", forKey: "effort"); defaults.synchronize()
        let reopened = try #require(UserDefaults(suiteName: name)); let config = TranslationPreferences.load(reopened)
        #expect(config.model == "gpt-5.6-terra"); #expect(config.effort == "low")
        reopened.set("gpt-4o-mini", forKey: "model")
        #expect(TranslationPreferences.load(reopened).effort == "low")
        #expect(try !TranslationPreferences.load(reopened).descriptor().supportsReasoning)
    }
    @Test func unknownSavedModelDoesNotFallback() {
        #expect(throws: (any Error).self) { try TranslationConfig(model: "old-unknown").descriptor() }
    }
    @Test func priceEstimatesAndUnknownUsageAreNotZero() throws {
        let config = TranslationConfig(); let descriptor = try config.descriptor()
        #expect(abs(descriptor.pricing.estimate(input: 1_000_000, output: 1_000_000)-1.4) < 1e-9)
        let unknown = TranslationUsage(result: TranslationResult(items: []), config: config, descriptor: descriptor, batchKey: "x")
        #expect(unknown.estimatedUSD == nil); #expect(unknown.inputTokens == nil)
        #expect(try Codec.decode(TranslationUsage.self, Codec.encode(unknown)) == unknown)
        let t = try CoreTests().parsed(); let estimate = TranslationCostEstimate(batches: TranslationBatch.make(t), config: config, model: descriptor)
        #expect(estimate.inputTokens > 0); #expect(estimate.outputTokens > 0); #expect(estimate.summary.contains("不是账单"))
    }
}
