import Foundation
import Testing
import Darwin
@testable import Core

struct V085CoreTests {
    private func envelope(_ value:Any,status:String="completed",reason:String?=nil)throws->Data {
        let text=String(decoding:try JSONSerialization.data(withJSONObject:value),as:UTF8.self)
        var root:[String:Any]=["status":status,"usage":["input_tokens":30,"output_tokens":6000,"output_tokens_details":["reasoning_tokens":178]],"output":[["content":[["type":"output_text","text":text]]]]]
        if let reason {root["incomplete_details"]=["reason":reason]}
        return try JSONSerialization.data(withJSONObject:root)
    }
    private var chunk:AnalysisChunk {AnalysisChunk(id:"block",targets:(0..<6).map{Cue(id:"cue-\($0)",start:$0*1000,end:($0+1)*1000,en:"sample \($0)")})}
    private func children()throws->[AnalysisChapter] {try HierarchicalAnalysis.build([.init(start:"c0001",title:"A",points:["one"]),.init(start:"c0003",title:"B",points:["two"]),.init(start:"c0005",title:"C",points:["three"])],chunk:chunk)}
    private func payload(_ starts:[String]=["p0001","p0003"],source:String="p0002")->[String:Any] {
        ["topics":starts.map{["start":$0,"title":"主题","summary":"概述"]},"overview":[["text":"要点","source":source]]]
    }
    @Test func compactSynthesisKeepsAllChildTextMembershipAndInternalReference()throws {
        let children=try children(),result=OpenAIAnalysisProvider.decodeCompactSynthesis(try envelope(payload()),proposed:children,config:AnalysisConfig(model:"gpt-4o-mini"))
        let doc=try #require(result.value)
        #expect(doc.chapters==children && doc.topics?.map{$0.subtopics.count} == [2,1])
        #expect(doc.overview.first?.chapterID==children[1].id)
        #expect(try Codec.decode(AnalysisDocument.self,Codec.encode(doc))==doc)
    }
    @Test func compactRejectsUnknownDuplicateOrderMissingOpeningAndBadReference()throws {
        for (starts,ref,code) in [(["p9999"],"p0002","unknown_id"),(["p0001","p0001"],"p0002","duplicate"),(["p0001","p0003","p0002"],"p0002","order"),(["p0002"],"p0002","coverage"),(["p0001"],"p9999","reference")] {
            let r=OpenAIAnalysisProvider.decodeCompactSynthesis(try envelope(payload(starts,source:ref)),proposed:try children(),config:AnalysisConfig(model:"gpt-4o-mini"))
            #expect(r.value==nil && r.result.analysisValidation?.code==code)
            #expect(r.result.outputTokens==6000)
        }
    }
    @Test func incompleteCannotBeSalvagedEvenWithParseableJSONAndUsageIsSaved()throws {
        var config=AnalysisConfig(model:"gpt-4o-mini");config.protocolVersion=3
        let r=OpenAIAnalysisProvider.decodeCompactSynthesis(try envelope(payload(),status:"incomplete",reason:"max_output_tokens"),proposed:try children(),config:config,requestID:"mock-request")
        #expect(r.value==nil)
        let a=try AnalysisAttempt(stage:"synthesis",config:config,result:r.result,outcome:"failed")
        #expect(a.validation?.code=="output_limit" && a.protocolVersion==3 && a.requestID=="mock-request")
        #expect(a.usage.outputTokens==6000 && a.usage.reasoningTokens==178)
        #expect(try Codec.decode(AnalysisAttempt.self,Codec.encode(a))==a)
    }
    @Test func explicitCompactContinuationRetainsLegacyPointsAndOnlyPendingChunks()throws {
        let transcript=Transcript(version:digest("mock"),original:Data("mock".utf8),format:"vtt",cues:chunk.targets)
        let plan=try AnalysisPlan.make(transcript),b=plan.chunks[0]
        var task=AnalysisTaskState(config:AnalysisConfig(model:"gpt-4o-mini"),plan:plan)
        task.completedChunks[b.id]=[AnalysisChapter(id:"saved",startCueID:b.targets[0].id,endCueID:b.targets.last!.id,title:"old",points:["a","b","c"])]
        let next=try task.compactContinuation()
        #expect(task.config.protocolVersion==nil && next.config.protocolVersion==3)
        #expect(next.pendingChunks.isEmpty && next.config.model==task.config.model && next.config.outputLimit==task.config.outputLimit)
        #expect(next.proposedChapters[0].points==task.proposedChapters[0].points)
        #expect(next.proposedChapters[0].memberCueIDs==b.targets.map(\.id))
        let r=OpenAIAnalysisProvider.decodeCompactSynthesis(try envelope(payload(["p0001"],source:"p0001")),proposed:next.proposedChapters,config:next.config)
        #expect(r.value != nil)
    }
    @Test func hiddenAttributesAreIncludedButDotfilesGeneratedAndSymlinksAreNot()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("LP085-scan-"+UUID().uuidString),folder=root.appendingPathComponent("CourseA/Week9/Lecture/Part")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        for name in ["Lecture 9.1.mp4","Lecture 9.2.mp4","Lecture 9.3.mp4","Lecture 9.4.mp4","Lecture 9.1.vtt",".hidden.mp4","a.lectureplayer-id.zh.vtt"] {
            let url=folder.appendingPathComponent(name);try Data(name.utf8).write(to:url);#expect(chflags(url.path,UInt32(UF_HIDDEN))==0)
        }
        #expect(chflags(folder.path,UInt32(UF_HIDDEN))==0)
        let dot=root.appendingPathComponent(".system");try FileManager.default.createDirectory(at:dot,withIntermediateDirectories:true);try Data("x".utf8).write(to:dot.appendingPathComponent("bad.mp4"))
        try FileManager.default.createSymbolicLink(at:folder.appendingPathComponent("link.mp4"),withDestinationURL:folder.appendingPathComponent("Lecture 9.1.mp4"))
        let scanner=DirectoryScanner(),one=try await scanner.scan(root,settle:.milliseconds(1)),two=try await scanner.scan(root,settle:.milliseconds(1))
        #expect(one.media.count==4 && one.files.count==5 && one.issues.isEmpty)
        #expect(Set(try ImportPlanner.scan([root]))==Set(one.files))
        #expect(DirectoryIndex.pendingGroups(one.media.map(\.url)).map{$0[0].lastPathComponent} == ["Lecture 9.1.mp4","Lecture 9.2.mp4","Lecture 9.3.mp4","Lecture 9.4.mp4"])
        #expect(one.media.map(\.identity).sorted()==two.media.map(\.identity).sorted())
        #expect(try folder.resourceValues(forKeys:[.isHiddenKey]).isHidden==true)
        var library=Library();DirectoryIndex.buildTree(one.directories,root:root,library:&library)
        #expect(library.folders.contains{$0.name=="Part"} && library.lectures.isEmpty)
    }
    @Test
    func syntheticHiddenCourseFilesReadOnlyScan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LP085-public-scan-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("CourseA/Week9/Lecture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for n in 1...4 {
            let url = folder.appendingPathComponent("Lecture 9.\(n).mp4")
            try Data("synthetic media \(n)".utf8).write(to: url)
            #expect(chflags(url.path, UInt32(UF_HIDDEN)) == 0)
        }
        for n in 1...12 {
            try Data("other synthetic media \(n)".utf8).write(to: root.appendingPathComponent("Other \(n).mp4"))
        }
        let result = try await DirectoryScanner().scan(root, settle: .milliseconds(10))
        let candidates = result.media.filter { $0.url.path.contains("/CourseA/Week9/Lecture/") }
        #expect(candidates.count == 4 && DirectoryIndex.pendingGroups(candidates.map(\.url)).count == 4)
        #expect(result.media.count == 16 && result.issues.isEmpty)
        #expect(candidates.allSatisfy { (try? $0.url.resourceValues(forKeys: [.isHiddenKey]).isHidden) == true })
    }
}
