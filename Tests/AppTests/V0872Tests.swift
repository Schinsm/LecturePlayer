import AppKit
import SwiftUI
import Foundation
import Testing
@testable import Core
@testable import LecturePlayer

@MainActor @Suite(.serialized) struct V0872Tests {
    func fixture() throws -> (AppStore,Lecture,URL,Transcript) {
        let (store,varT)=try V052AppTests().fixture();let root=store.repository!.root
        var t=varT;var l=store.library.lectures[0]
        l.sources=nil;l.path=root.appendingPathComponent("s1.mp4").path;l.subtitlePath=root.appendingPathComponent("source.vtt").path
        try Data("test video".utf8).write(to:URL(fileURLWithPath:l.path));try t.original.write(to:URL(fileURLWithPath:l.subtitlePath!))
        t.translations[t.cues[0].id]=Translation(ai:"测试译文",cacheKey:"mock")
        var attempt=TranslationAttempt(model:"mock",batchKey:"mock",requestID:nil,expected:1,outcome:"完成");attempt.sidecarSeconds=0.123;t.attempts=[attempt]
        try store.repository!.write(t,for:l.id);store.updateLecture(l.id){$0=l};store.flushMetadata()
        return (store,l,try store.repository!.transcriptURL(l.id,t.version),t)
    }
    func stamp(_ url:URL) throws -> String {
        let a=try FileManager.default.attributesOfItem(atPath:url.path)
        return "\(a[.systemFileNumber]!)|\(a[.modificationDate]!)|\(digest(try Data(contentsOf:url)))"
    }
    @Test func realDelegateAnswersUnknownMenuSelectorsWithoutRecursion() {
        _=NSApplication.shared
        let split=StudySplit<Text,Text>.Split(frame:NSRect(x:0,y:0,width:1200,height:700))
        split.isVertical=true;split.addArrangedSubview(NSView());split.addArrangedSubview(NSView())
        let host=ReaderSplitContainer(split:split,delegate:StudySplit<Text,Text>.SplitDelegate(split))
        #expect(split.delegate !== split)
        let window=NSWindow(contentRect:host.bounds,styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=host;defer{window.close()}
        let menu=NSMenu();menu.addItem(withTitle:"Sidebar",action:NSSelectorFromString("toggleSidebar:"),keyEquivalent:"")
        for i in 0..<1000 {
            _=split.responds(to:NSSelectorFromString(i%2==0 ? "toggleSidebar:" : "unknownMenuAction:"));menu.update()
            if i%20==0 {split.setRightVisible(i%40==0);host.layout()}
        }
        #expect(split.arrangedSubviews.count==2)
    }
    @Test func unchangedRecoveryPreservesFilesAndHistoricalTiming() async throws {
        let (s,l,url,t)=try fixture();let writer=s.translation.writer
        let first=try await writer.saveFiles(lesson:l,url:url)
        let files=Array(first.sidecars!.keys).map{URL(fileURLWithPath:$0)}+[url]
        let before=try files.map(stamp)
        for _ in 0..<20 {_=try await writer.saveFiles(lesson:l,url:url,onlyIfNeeded:true)}
        #expect(try files.map(stamp)==before)
        #expect(try await writer.read(url).attempts==t.attempts)
        // Explicit save is also a no-op when content is unchanged.
        _=try await writer.saveFiles(lesson:l,url:url)
        #expect(try files.map(stamp)==before)
        try FileManager.default.removeItem(at:files[0]);_=try await writer.saveFiles(lesson:l,url:url,onlyIfNeeded:true)
        #expect(FileManager.default.fileExists(atPath:files[0].path))
        #expect(try await writer.read(url).usage==nil)
    }
    @Test func changedContentAndEditedAlternateAreSafeAndIdempotent() async throws {
        let (s,l,url,_)=try fixture();let writer=s.translation.writer
        let first=try await writer.saveFiles(lesson:l,url:url)
        let file=URL(fileURLWithPath:first.sidecars!.keys.first{$0.hasSuffix(".md")}!)
        try Data("my personal edit".utf8).write(to:file)
        var t=try await writer.read(url);t.translations[t.cues[1].id]=Translation(ai:"new",cacheKey:"mock");try s.repository!.write(t,for:l.id)
        let result=try await writer.saveFiles(lesson:l,url:url)
        #expect(result.fileOutcome == .conflict)
        #expect(try String(contentsOf:file,encoding:.utf8)=="my personal edit")
        let all=result.sidecars!.keys.map{URL(fileURLWithPath:$0)}+[url];let before=try all.map(stamp)
        _=try await writer.saveFiles(lesson:l,url:url)
        #expect(try all.map(stamp)==before)
    }
    @Test func failedSidecarDoesNotRetryOnScansOrChangeHistory() async throws {
        let (s,varL,url,t)=try fixture();var l=varL;l.path=s.repository!.root.appendingPathComponent("missing/s1.mp4").path
        let writer=s.translation.writer
        let result=try await writer.saveFiles(lesson:l,url:url)
        #expect(result.fileOutcome == .failed && result.fileStatus.contains("文件或目录不可用"))
        let before=try stamp(url)
        for _ in 0..<10 {_=try await writer.saveFiles(lesson:l,url:url,onlyIfNeeded:true)}
        #expect(try stamp(url)==before)
        try FileManager.default.createDirectory(at:URL(fileURLWithPath:l.path).deletingLastPathComponent(),withIntermediateDirectories:true)
        let saved=try await writer.saveFiles(lesson:l,url:url)
        #expect(saved.fileOutcome == .written && saved.transcript.attempts==t.attempts && saved.transcript.usage==nil)
    }
    @Test func errorClassificationAndBoundedPrivateDiagnostics() throws {
        #expect(StorageIssue(NSError(domain:NSPOSIXErrorDomain,code:28)).kind == .noSpace)
        #expect(StorageIssue(NSError(domain:NSCocoaErrorDomain,code:NSFileWriteNoPermissionError)).kind == .permission)
        #expect(StorageIssue(NSError(domain:NSPOSIXErrorDomain,code:2)).kind == .unavailable)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        for _ in 0..<1200 {StorageDiagnostics.record(root:root,operation:.sidecar,outcome:.failed,error:NSError(domain:"private-key",code:28,userInfo:[NSLocalizedDescriptionKey:"SECRET subtitle"]))}
        let files=try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("Diagnostics"),includingPropertiesForKeys:nil)
        #expect(files.count<=2)
        for file in files {let data=try Data(contentsOf:file);#expect(data.count<=StorageDiagnostics.capacity);#expect(!String(decoding:data,as:UTF8.self).contains("SECRET"));#expect(!String(decoding:data,as:UTF8.self).contains("private-key"))}
    }
    @Test func storageFailureStopsNewRequestsKeepsInFlightLease() async throws {
        let (s,_,_,_)=try fixture();let lease=try await s.requests.acquire(lesson:UUID())
        s.storageFailed(NSError(domain:NSPOSIXErrorDomain,code:28))
        // Let the main-actor failure notification reach the scheduler actor.
        try await Task.sleep(for:.milliseconds(20))
        #expect(await s.requests.activeCount==1)
        do {_=try await s.requests.acquire(lesson:UUID());Issue.record("Dispatched after storage failure")}catch{}
        await s.requests.release(lease)
        #expect(s.error?.contains("磁盘空间不足")==true)
    }
}

@MainActor @Suite(.serialized) struct V0872StorageFaults {
    @Test func fullDiskKeepsOriginalAndDoesNotRetryDuringRecovery() async throws {
        let (s,l,url,t)=try V0872Tests().fixture();let before=try V0872Tests().stamp(url)
        let counter=LockedWriteCounter()
        let writer=TranslationWriter {_,_ in counter.increment();throw NSError(domain:NSPOSIXErrorDomain,code:28)}
        do {_=try await writer.saveFiles(lesson:l,url:url);Issue.record("Expected simulated ENOSPC")}catch{#expect(StorageIssue(error).kind == .noSpace)}
        for _ in 0..<10 {_=try await writer.saveFiles(lesson:l,url:url,onlyIfNeeded:true)}
        #expect(counter.count==1);#expect(try V0872Tests().stamp(url)==before)
        #expect(try await writer.read(url)==t)
        // An explicit file retry may attempt the write, but never invokes any service.
        do {_=try await writer.saveFiles(lesson:l,url:url)}catch{}
        #expect(counter.count==2)
        let recovered=try await s.translation.writer.saveFiles(lesson:l,url:url)
        #expect(recovered.transcript.translations==t.translations && recovered.transcript.attempts==t.attempts)
    }
    @Test func readOnlyDirectoryPreservesCachedTranslationAndExplicitRetryWorks() async throws {
        let (s,varL,url,t)=try V0872Tests().fixture();var l=varL
        let dir=s.repository!.root.appendingPathComponent("read-only");try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        l.path=dir.appendingPathComponent("s1.mp4").path
        try FileManager.default.setAttributes([.posixPermissions:0o555],ofItemAtPath:dir.path)
        defer{try? FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:dir.path)}
        let result=try await s.translation.writer.saveFiles(lesson:l,url:url)
        #expect(result.fileOutcome == .failed && result.fileStatus.contains("权限"))
        #expect(result.transcript.translations==t.translations && result.transcript.usage==nil)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:dir.path)
        let retry=try await s.translation.writer.saveFiles(lesson:l,url:url)
        #expect(retry.fileOutcome == .written && retry.transcript.translations==t.translations)
    }
}
private final class LockedWriteCounter:@unchecked Sendable {
    private let lock=NSLock();private var value=0
    var count:Int {lock.lock();defer{lock.unlock()};return value}
    func increment(){lock.lock();value += 1;lock.unlock()}
}
