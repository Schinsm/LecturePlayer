import Foundation
import Testing
@testable import Core

struct V05TranslationTests {
    @Test func limitsKeepOriginalCuesAndContext() throws {
        var t=try CoreTests().parsed()
        t.cues=(0..<143).map { Cue(id:"original-\($0)",sourceID:"vtt-\($0)",start:$0*1000,end:$0*1000+900,en:String(repeating:"a",count:60)) }
        let batches=TranslationBatch.make(t,budget:4000,maxCues:30)
        #expect(batches.map(\.targets.count) == [30,30,30,30,23])
        #expect(batches.flatMap(\.targets) == t.cues)
        #expect(batches[1].context.count == 4)
        #expect(TranslationBatch.make(t,maxCues:10).allSatisfy { $0.targets.count <= 10 })
        t.cues[1].en=String(repeating:"b",count:5000)
        #expect(TranslationBatch.make(t).contains { $0.targets.count == 1 && $0.targets[0].id == "original-1" })
    }
    @Test func outOfOrderPartialDuplicatesEmptyAndExtra() throws {
        let t=try CoreTests().parsed(),ids=t.cues.map(\.id)
        let reversed=[TranslatedItem(id:ids[1],zh:"二"),TranslatedItem(id:ids[0],zh:"一")]
        let ordered=TranslationAssessment(reversed,targets:t.cues)
        #expect(ordered.complete && ordered.accepted.map(\.id) == ids)
        let duplicate=TranslationAssessment(reversed+[reversed[0],TranslatedItem(id:"unrecognized",zh:"extra")],targets:t.cues)
        #expect(duplicate.accepted.map(\.id) == [ids[0]] && duplicate.duplicates == 1 && duplicate.extra == 1)
        let empty=TranslationAssessment([TranslatedItem(id:ids[0],zh:" ")],targets:t.cues)
        #expect(empty.empty == 1 && empty.missing == 1 && empty.accepted.isEmpty)
    }
    @Test func incompleteAndMalformedKeepUsageButNeverSalvage() throws {
        let t=try CoreTests().parsed()
        for status in ["completed","incomplete"] {
            let data=try JSONSerialization.data(withJSONObject:["status":status,"output":[["content":[["type":"output_text","text":"{broken"]]]],"usage":["input_tokens":50,"output_tokens":12]])
            let result=try OpenAIProvider.decode(data,targets:t.cues)
            #expect(result.items.isEmpty && result.problem != nil && result.inputTokens == 50 && result.outputTokens == 12)
        }
    }
    @Test func requiredKeyedResponseAndMissingDetection() throws {
        let t=try CoreTests().parsed()
        for values in [["c002":"二","c001":"一"], ["c001":"一"], ["c001":"", "c002":"二"]] {
            let text=String(data:try JSONSerialization.data(withJSONObject:["translations":values]),encoding:.utf8)!
            let data=try JSONSerialization.data(withJSONObject:["status":"completed","output":[["content":[["type":"output_text","text":text]]]]])
            let result=try OpenAIProvider.decode(data,targets:t.cues,shortIDs:true)
            let check=TranslationAssessment(result.items,targets:t.cues)
            #expect(check.complete == (values.count == 2 && values["c001"] != ""))
            #expect(check.missing == (values.count == 1 ? 1 : 0))
            #expect(check.empty == (values["c001"] == "" ? 1 : 0))
        }
    }
    @Test func shortIDsMapWithoutChangingTimeline() throws {
        let t=try CoreTests().parsed()
        let text=String(data:try JSONSerialization.data(withJSONObject:["translations":[["id":"c002","zh":"二"],["id":"c001","zh":"一"]]]),encoding:.utf8)!
        let data=try JSONSerialization.data(withJSONObject:["status":"completed","output":[["content":[["type":"output_text","text":text]]]]])
        let result=try OpenAIProvider.decode(data,targets:t.cues,shortIDs:true)
        #expect(TranslationAssessment(result.items,targets:t.cues).accepted.map(\.id) == t.cues.map(\.id))
    }
}

struct RefreshPolicyTests {
    @Test func automaticManualAndIntervalDecisions() {
        let now=Date(timeIntervalSince1970:5000)
        #expect(RefreshPolicy.automatic.due(last:now,now:now,startup:true))
        #expect(!RefreshPolicy.automatic.due(last:now,now:now))
        #expect(!RefreshPolicy.manual.due(last:nil,now:now,startup:true))
        #expect(!RefreshPolicy.hourly.due(last:now.addingTimeInterval(-3599),now:now))
        #expect(RefreshPolicy.hourly.due(last:now.addingTimeInterval(-3600),now:now))
        #expect(RefreshPolicy.quarterHour.due(last:now.addingTimeInterval(-900),now:now))
        #expect(!RefreshPolicy.hourly.due(last:now,now:now.addingTimeInterval(30)))
    }
}
