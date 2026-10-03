import Foundation
import Testing
@testable import Core

@Suite struct V089CoreTests {
    func fixture() throws -> (URL,Lecture,Transcript) {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("lp089-\(UUID())")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let original=Data("WEBVTT\n\none\n00:00:01.000 --> 00:00:02.000\nHello\n\ntwo\n00:00:03.000 --> 00:00:04.000\nWorld\n".utf8)
        var t=try SubtitleParser.parse(original,format:"vtt")
        t.translations[t.cues[0].id]=Translation(ai:"你好",cacheKey:"mock")
        t.translations[t.cues[1].id]=Translation(ai:"世界",cacheKey:"mock")
        let subtitle=dir.appendingPathComponent("source.vtt");try original.write(to:subtitle)
        var l=Lecture(title:"Long / lesson",courseID:UUID(),folderID:nil,url:dir.appendingPathComponent("s1.mp4"),bookmark:nil,identity:"fixture")
        l.subtitlePath=subtitle.path;l.transcriptVersion=t.version
        return (dir,l,t)
    }
    @Test func availabilityNeverInventsQueueAndShowsBlockers() throws {
        #expect(AnalysisAvailability(saved:nil).label=="未生成总结")
        #expect(AnalysisAvailability(saved:nil,queued:true).state == .queued)
        #expect(AnalysisAvailability(saved:nil,queued:true,queuePaused:true).state == .paused)
        #expect(AnalysisAvailability(saved:nil,running:true).state == .generating)
        #expect(AnalysisAvailability(saved:nil,hasOlder:true).state == .oldSource)
        #expect(AnalysisAvailability(saved:nil,hasTimedSource:false).reason?.contains("VTT")==true)
        #expect(AnalysisAvailability(saved:nil,keyConfigured:false).reason?.contains("Key")==true)
        #expect(AnalysisAvailability(saved:nil,modelAvailable:false).reason != nil)
        #expect(AnalysisAvailability(saved:nil,serviceTest:true).reason?.contains("连接测试")==true)
    }
    @Test func servicesStaySeparateAndRepeatedBatchesReuseTwoPaths() throws {
        let (root,l,original)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        var t=original
        let first=try SidecarWriter.writeReport(t,lesson:l,beside:URL(fileURLWithPath:l.subtitlePath!))
        t.variants?["openAI"]?.generatedFiles=first.records
        for n in 0..<30 {
            t.translations[t.cues[0].id]=Translation(ai:"更新 \(n)",cacheKey:"mock")
            let result=try SidecarWriter.writeReport(t,lesson:l,beside:URL(fileURLWithPath:l.subtitlePath!))
            #expect(Set(result.files.keys)==Set(first.files.keys))
            t.variants?["openAI"]?.generatedFiles=result.records
        }
        var other=t.viewing("apple");other.translations=original.translations
        let second=try SidecarWriter.writeReport(other,lesson:l,beside:URL(fileURLWithPath:l.subtitlePath!))
        #expect(second.files.count==2 && Set(second.files.keys).isDisjoint(with:Set(first.files.keys)))
        #expect(try ImportPlanner.scan([root]).count==1)
        var renamed=l;renamed.title="Different title"
        let again=try SidecarWriter.writeReport(t,lesson:renamed,beside:URL(fileURLWithPath:l.subtitlePath!))
        #expect(Set(again.files.keys)==Set(first.files.keys));#expect(again.writes==0)
        let before=try again.records.map{try FileManager.default.attributesOfItem(atPath:$0.path)[.systemFileNumber] as! NSNumber}
        _=try SidecarWriter.writeReport(t,lesson:renamed,beside:URL(fileURLWithPath:l.subtitlePath!))
        #expect(try again.records.map{try FileManager.default.attributesOfItem(atPath:$0.path)[.systemFileNumber] as! NSNumber}==before)
    }
    @Test func journalRecoversLostMetadataAndEditedFileUsesOneAlternate() throws {
        let (root,l,original)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        var t=original
        let first=try SidecarWriter.writeReport(t,lesson:l,beside:root)
        let edited=try #require(first.records.first{$0.format == .chineseVTT})
        try Data("human edited".utf8).write(to:URL(fileURLWithPath:edited.path))
        let replacement=try SidecarWriter.writeReport(t,lesson:l,beside:root)
        #expect(replacement.outcome == .conflict)
        // Deliberately never commit records: the next call must recover the intent, not create another copy.
        for n in 0..<8 {
            t.translations[t.cues[0].id]=Translation(ai:"下一批 \(n)",cacheKey:"mock")
            let result=try SidecarWriter.writeReport(t,lesson:l,beside:root)
            #expect(Set(result.files.keys)==Set(replacement.files.keys))
        }
        #expect(try String(contentsOfFile:edited.path,encoding:.utf8)=="human edited")
    }
    @Test func legacyOwnershipAndCleanupRequireExactProof() throws {
        let (root,l,t)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let files=try SidecarWriter.writeReport(t,lesson:l,beside:root)
        let stem="source.lectureplayer-\(l.id.uuidString.prefix(8))-\(t.version.prefix(8))"
        var partial=t;partial.translations.removeValue(forKey:t.cues[1].id)
        let old=root.appendingPathComponent(stem+".openai.abcdef.zh.vtt")
        let data=try Exporter.render(partial,kind:.chineseVTT,translatedOnly:true);try data.write(to:old)
        let map=[old.path:digest(data),root.appendingPathComponent(stem+".apple.zh.vtt").path:"other"]
        #expect(GeneratedFiles.legacyFiles(map,lessonID:l.id,version:t.version,serviceID:"openAI").count==1)
        #expect(HistoricalExportAudit.evaluate(url:old,knownHash:digest(data),transcript:t,lesson:l,replacements:files.records).candidate)
        try Data("edited".utf8).write(to:old)
        #expect(!HistoricalExportAudit.evaluate(url:old,knownHash:digest(data),transcript:t,lesson:l,replacements:files.records).candidate)
        try data.write(to:old)
        #expect(!HistoricalExportAudit.evaluate(url:old,knownHash:nil,transcript:t,lesson:l,replacements:files.records).candidate)
        #expect(!HistoricalExportAudit.evaluate(url:old,knownHash:digest(data),transcript:partial,lesson:l,replacements:files.records).candidate)
        var empty=t;empty.translations[t.cues[1].id]=Translation(ai:" ",cacheKey:"mock")
        #expect(!HistoricalExportAudit.evaluate(url:old,knownHash:digest(data),transcript:empty,lesson:l,replacements:files.records).candidate)
    }
    @Test func perLessonReadIgnoresOtherCorruptionAndInventoryReportsIt() async throws {
        let (root,l,t)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let repo=AnalysisRepository(root:root)
        let record=LessonAnalysis(lessonID:l.id,sourceVersion:t.version)
        try await repo.save(record)
        let bad=UUID(),url=AnalysisRepository.fileURL(root:root,lessonID:bad,sourceVersion:t.version)
        try Data("broken".utf8).write(to:url)
        #expect(try await repo.all(lessonID:l.id)==[record])
        let inventory=try await repo.inventory();#expect(inventory.records==[record]);#expect(inventory.errors[bad] != nil)
        #expect(throws:(any Error).self){try AnalysisRepository.readAll(root:root)}
    }
    @Test func emptyVariantAndUnsafeOutputFolderNeverGenerateFiles() throws {
        let (root,l,original)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        var t=original;t.translations=[:]
        #expect(try SidecarWriter.writeReport(t,lesson:l,beside:root).files.isEmpty)
        let folder=root.appendingPathComponent("LecturePlayer")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try Data("user".utf8).write(to:folder.appendingPathComponent("notes.txt"))
        #expect(throws:(any Error).self){try SidecarWriter.writeReport(original,lesson:l,beside:root)}
        #expect(!FileManager.default.fileExists(atPath:folder.appendingPathComponent(GeneratedFiles.marker).path))
    }
}

extension V089CoreTests {
    @Test func diskFullAndReadOnlyPreservePriorBytesAndRecoverPartialWrite() throws {
        let (root,l,original)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let first=try SidecarWriter.writeReport(original,lesson:l,beside:root)
        var t=original;t.variants?["openAI"]?.generatedFiles=first.records
        t.translations[t.cues[0].id]=Translation(ai:"new content",cacheKey:"mock")
        let before=try first.records.map{try Data(contentsOf:URL(fileURLWithPath:$0.path))}
        for code in [28,13] {
            do {
                _=try GeneratedFiles.write(t,lesson:l,hideSpeakers:false,writeFile:{_,_,_ in throw NSError(domain:NSPOSIXErrorDomain,code:code)})
                Issue.record("Expected write failure")
            } catch {#expect(StorageIssue(error).kind == (code==28 ? .noSpace:.permission))}
            #expect(try first.records.map{try Data(contentsOf:URL(fileURLWithPath:$0.path))}==before)
        }
        var count=0
        do {
            _=try GeneratedFiles.write(t,lesson:l,hideSpeakers:false,writeFile:{data,url,options in
                count += 1;if count==2 {throw NSError(domain:NSPOSIXErrorDomain,code:28)}
                try data.write(to:url,options:options)
            })
        }catch{}
        let recovered=try SidecarWriter.writeReport(t,lesson:l,beside:root)
        #expect(Set(recovered.files.keys)==Set(first.files.keys));#expect(recovered.writes==1)
    }
}
