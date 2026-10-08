import AppKit
import AVFoundation
import SwiftUI
import Security
import Testing
import Core
@testable import LecturePlayer

@MainActor @Suite(.serialized) struct V0810Tests {
    @Test func credentialStatusDistinguishesMissingFromPermissionAndFailures() {
        #expect(CredentialAvailability.keychainStatus(errSecSuccess) == .available)
        #expect(CredentialAvailability.keychainStatus(errSecItemNotFound) == .missing)
        #expect(CredentialAvailability.keychainStatus(errSecInteractionNotAllowed) == .authorizationRequired)
        #expect(CredentialAvailability.keychainStatus(errSecAuthFailed) == .authorizationRequired)
        #expect(CredentialAvailability.keychainStatus(errSecNotAvailable) == .unavailable(errSecNotAvailable))
    }
    @Test func coldCheckPublishesWithoutSettingsOrAPITestAndServicesStayIndependent() async throws {
        let cache=KeychainAvailability(stateProbe:{$0 == .openAI ? .available : .missing})
        #expect(cache.state(.openAI) == .checking)
        cache.refresh(.openAI);cache.refresh(.azure)
        for _ in 0..<100 {if cache.state(.openAI) != .checking && cache.state(.azure) != .checking {break};try await Task.sleep(for:.milliseconds(10))}
        #expect(cache.state(.openAI) == .available)
        #expect(cache.state(.azure) == .missing)
        #expect(await cache.validate(.openAI) == .available)
    }
    @Test func invalidationDuringSlowProbeDiscardsStaleResult() async throws {
        let probe=SlowCredentialProbe()
        let cache=KeychainAvailability(stateProbe:{_ in probe.read()})
        cache.refresh(.openAI)
        for _ in 0..<100 {if probe.started {break};try await Task.sleep(for:.milliseconds(5))}
        cache.invalidate(.openAI)
        probe.release.signal()
        for _ in 0..<100 {if cache.state(.openAI) == .missing {break};try await Task.sleep(for:.milliseconds(10))}
        #expect(cache.state(.openAI) == .missing)
    }
    @Test func chapterAndTranscriptFollowAreIndependentAndKeepGapLocation() {
        let s=ReaderSession()
        s.browseChapters();#expect(!s.chapterFollowing && s.reader.following)
        s.followChapters();s.reader.browse();#expect(s.chapterFollowing && !s.reader.following)
        s.chapterQuery="formula";s.browseChapters();s.followChapters()
        #expect(s.chapterQuery.isEmpty && s.chapterFollowing && !s.reader.following)
        let entries=[ChapterPositionIndex.Entry(id:"a",start:10,end:20),.init(id:"b",start:30,end:40)]
        #expect(ChapterPositionIndex.readingAnchor(entries,seconds:9)==nil)
        #expect(ChapterPositionIndex.readingAnchor(entries,seconds:24)=="a")
        #expect(ChapterPositionIndex.readingAnchor(entries,seconds:44-14)=="b")
        #expect(ChapterPositionIndex.current(entries,seconds:24)==nil)
        #expect(ChapterPositionIndex.readingAnchor(entries,seconds:.nan)==nil)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LP_LIBRARY_COPY"] != nil))
    func isolatedLibraryRoundTripPreservesRecords() async throws {
        let root=URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["LP_LIBRARY_COPY"]))
        let repository=try Repository(root:root), library=try repository.load()
        var originals:[UUID:Transcript]=[:]
        for lesson in library.lectures {if let transcript=try repository.read(lesson) {originals[lesson.id]=transcript}}
        let before=try await AnalysisRepository(root:root).inventory()
        try repository.save(library)
        let reopened=try Repository(root:root).load()
        #expect(reopened==library)
        for lesson in reopened.lectures {#expect(try repository.read(lesson)==originals[lesson.id])}
        let after=try await AnalysisRepository(root:root).inventory()
        #expect(before.records==after.records && before.errors==after.errors)
        print("ISOLATED_LIBRARY lessons=\(library.lectures.count) transcripts=\(originals.count) analyses=\(before.records.count) existingAnalysisErrors=\(before.errors.count)")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LP_RENDER_WINDOW"] == "1"))
    func firstFrameSurvivesRepeatedSurfaceMounting() async throws {
        _=NSApplication.shared
        let (_,library,_)=try PersistenceTests().fixture()
        let playback=Playback();defer{playback.close()}
        let window=NSWindow(contentRect:CGRect(x:0,y:0,width:640,height:400),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;defer{window.orderOut(nil);window.close()}
        window.orderFrontRegardless()
        let defaults=UserDefaults(suiteName:"LP0810.Render."+UUID().uuidString)!
        let preferences=PictureInPicturePreferences(defaults:defaults)
        for iteration in 0..<10 {
            playback.load(library.lectures[0])
            let canvas=VideoCanvas.Canvas(frame:.zero)
            window.contentView=canvas
            canvas.configure(playback,layout:.screen,swapped:false,preferences:preferences)
            canvas.setFrameSize(CGSize(width:640,height:400))
            try await V04PlaybackTests().wait(playback)
            canvas.configure(playback,layout:.screen,swapped:false,preferences:preferences)
            for _ in 0..<100 {if canvas.videos[0].isReadyForDisplay {break};try await Task.sleep(for:.milliseconds(50))}
            #expect(canvas.videos[0].isReadyForDisplay,"Missing first frame on mount \(iteration)")
            #expect(canvas.videos[0].bounds.width==640)
            canvas.tearDown();canvas.removeFromSuperview();playback.close()
        }
        print("RENDER_WINDOW completed=10")
    }
    @Test func canvasSizesAndBindsOnFirstConfigureWithoutManualLayout() async throws {
        _=NSApplication.shared
        let (_,library,_)=try PersistenceTests().fixture()
        let playback=Playback();defer{playback.close()}
        playback.load(library.lectures[0]);try await V04PlaybackTests().wait(playback)
        let canvas=VideoCanvas.Canvas(frame:.zero)
        let window=NSWindow(contentRect:CGRect(x:0,y:0,width:800,height:500),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;defer{canvas.tearDown();window.close()}
        window.contentView?.addSubview(canvas)
        let defaults=UserDefaults(suiteName:"LP0810.Frame."+UUID().uuidString)!
        canvas.configure(playback,layout:.screen,swapped:false,preferences:PictureInPicturePreferences(defaults:defaults))
        canvas.setFrameSize(CGSize(width:800,height:450))
        #expect(canvas.videos[0].frame==canvas.bounds)
        #expect(canvas.videos[0].playerLayer.player === playback.player)
        #expect(canvas.videos[0].playerLayer.superlayer === canvas.videos[0].layer)
        canvas.videos[0].playerLayer.removeFromSuperlayer()
        canvas.videos[0].synchronizeAttachment()
        #expect(canvas.videos[0].playerLayer.superlayer === canvas.videos[0].layer)
        let count=canvas.videos[0].attachmentCount
        canvas.configure(playback,layout:.screen,swapped:false,preferences:PictureInPicturePreferences(defaults:defaults))
        #expect(canvas.videos[0].attachmentCount==count)
        #expect(playback.player.rate==0 && playback.position==library.lectures[0].state.position)
    }
}

private final class SlowCredentialProbe:@unchecked Sendable {
    let release=DispatchSemaphore(value:0)
    private let lock=NSLock()
    private var count=0
    var started:Bool {lock.lock();defer{lock.unlock()};return count>0}
    func read()->CredentialAvailability {
        lock.lock();count += 1;let n=count;lock.unlock()
        if n==1 {_=release.wait(timeout:.now()+3);return .available}
        return .missing
    }
}
