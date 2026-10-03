import Foundation
import Testing
@testable import LecturePlayer
@testable import Core

@Suite(.serialized) @MainActor struct V042AppTests {
    func wait(_ store: AppStore) async throws {
        for _ in 0..<800 { if !store.scanning { return }; try await Task.sleep(for:.milliseconds(20)) }
        Issue.record("scan timed out")
    }
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LP042-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); return DirectoryIndex.canonical(root)
    }
    @Test func newLibraryShowsEmptyFoldersAndSixVideoCandidates() async throws {
        let data = try root(), media = data.appendingPathComponent("Recordings")
        let store = AppStore(root:data)
        for subject in ["CourseC","CourseA","IM","CourseB"] {
            for week in ["Week2","Week8","Week10"] { try FileManager.default.createDirectory(at:media.appendingPathComponent(subject + "/" + week),withIntermediateDirectories:true) }
            if subject != "CourseC" { for view in ["s1","s2"] { try Data((subject+view).utf8).write(to: media.appendingPathComponent("\(subject)/Week8/T-\(view)-full.mp4")) } }
        }
        store.library.directoryRoot = media.path; store.refreshDirectory(); try await wait(store)
        #expect(store.library.courses.count == 4 && store.library.folders.count == 12 && store.library.lectures.isEmpty)
        #expect(store.pendingFiles.count == 6 && DirectoryIndex.pendingGroups(store.pendingFiles).count == 3)
        #expect(store.scanSummary.contains("6 个视频") && store.scanSummary.contains("3 堂"))
        store.refreshDirectory(); store.refreshDirectory(); try await wait(store)
        #expect(store.library.courses.count == 4 && store.library.folders.count == 12)
        try FileManager.default.moveItem(at:media,to:data.appendingPathComponent("offline")); store.refreshDirectory(); try await wait(store)
        #expect(store.scanSummary.contains("失败") && store.pendingFiles.count == 6 && store.library.courses.count == 4)
    }
    @Test func changingRootDiscardsOldResult() async throws {
        let data = try root(), a=data.appendingPathComponent("A"),b=data.appendingPathComponent("B")
        for (base,name) in [(a,"Old/Week1"),(b,"New/Week8")] { try FileManager.default.createDirectory(at:base.appendingPathComponent(name),withIntermediateDirectories:true) }
        let store=AppStore(root:data); store.library.directoryRoot=a.path; store.refreshDirectory()
        try await Task.sleep(for:.milliseconds(50)); store.library.directoryRoot=b.path; store.rootGeneration=UUID(); store.refreshDirectory(); try await wait(store)
        #expect(store.library.courses.map(\.name) == ["New"] && store.scanResult?.root.path == b.path)
    }
    @Test func relinkUnknownHashKeepsIdentityProgressAndCache() async throws {
        let (data, originalLibrary, originalTranscript)=try PersistenceTests().fixture()
        let store=AppStore(root:data); var library=originalLibrary
        library.lastLecture=nil; library.lectures[0].path=data.appendingPathComponent("gone/T-s1-full.mp4").path
        library.lectures[0].state.offset=14
        var t=originalTranscript; t.translations[t.cues[0].id]=Translation(ai:"保留",cacheKey:"mock")
        store.library=library; try store.repository?.write(t,for:library.lectures[0].id); try store.repository?.save(library)
        let media=data.appendingPathComponent("Recordings/CourseA/Week8"); try FileManager.default.createDirectory(at:media,withIntermediateDirectories:true)
        let video=media.appendingPathComponent("T-s1-full.mp4"); try Data("same user confirmed recording".utf8).write(to:video)
        store.library.directoryRoot=media.deletingLastPathComponent().deletingLastPathComponent().path
        let before=store.library.lectures[0]
        store.refreshDirectory(); try await wait(store)
        #expect(store.library.lectures[0].path == before.path) // name alone must not silently rebind
        try await store.relinkMedia(before.id,sourceID:before.mediaSources[0].id,url:video)
        let after=store.library.lectures[0]
        #expect(after.id == before.id && after.state == before.state && after.marks == before.marks)
        #expect(after.path == video.path && after.directoryPath == DirectoryIndex.canonical(media).path)
        #expect(try store.repository?.read(after) == t)
        let snapshots=try FileManager.default.contentsOfDirectory(at:data,includingPropertiesForKeys:nil).filter { $0.lastPathComponent.hasPrefix("before-relink") }
        let snapshot=try Codec.decode(Backup.self,Data(contentsOf:try #require(snapshots.first)))
        #expect(snapshot.library.lectures[0].path == before.path && snapshot.library.directoryBookmark == nil)
        store.current=after.id; store.transcript=t; store.translation.start(store:store,ids:Set(t.translations.keys))
        #expect(!store.translation.running && store.translation.status.contains("没有发起请求"))
        let reopened=try Repository(root:data).load(); #expect(reopened.lectures[0].state == before.state)
    }
    @Test func snapshotFailurePreventsRelinkAndChangingImportDoesNotCommit() async throws {
        let (data, original, transcript)=try PersistenceTests().fixture(); let store=AppStore(root:data)
        store.library=original; try store.repository?.save(original); try store.repository?.write(transcript,for:original.lectures[0].id)
        let video=data.appendingPathComponent("replacement.mp4"); try Data("replacement".utf8).write(to:video)
        let transcriptURL=try #require(try store.repository?.transcriptURL(original.lectures[0].id,transcript.version))
        try Data("broken".utf8).write(to:transcriptURL)
        do { try await store.relinkMedia(original.lectures[0].id,sourceID:original.lectures[0].mediaSources[0].id,url:video); Issue.record("bad snapshot accepted") } catch {}
        #expect(store.library == original)
        try store.repository?.write(transcript,for:original.lectures[0].id)
        let task=Task { try await store.importLesson(row:ImportRow(video:video,title:"changing"),managed:false) }
        try await Task.sleep(for:.milliseconds(100)); try Data("different larger video".utf8).write(to:video)
        do {try await task.value; Issue.record("changing video imported")} catch {}
        #expect(store.library.lectures.count == 1)
    }
    @Test func foregroundDirectoryWatcherRefreshesNestedFolder() async throws {
        let data=try root(), media=data.appendingPathComponent("Recordings"),folder=media.appendingPathComponent("CourseA/Week8")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let store=AppStore(root:data); store.watchesEnabled=true; store.library.directoryRoot=media.path
        store.refreshDirectory(); try await wait(store)
        try Data("new screen".utf8).write(to:folder.appendingPathComponent("T-s1-full.mp4"))
        for _ in 0..<200 { if store.pendingFiles.count == 1 { break }; try await Task.sleep(for:.milliseconds(30)) }
        #expect(store.pendingFiles.count == 1)
        try FileManager.default.moveItem(at:folder,to:media.appendingPathComponent("CourseA/Week9"))
        for _ in 0..<200 { if store.library.folders.contains(where: { $0.name == "Week9" }) { break }; try await Task.sleep(for:.milliseconds(30)) }
        #expect(store.library.folders.contains { $0.name == "Week9" })
        store.directoryWatch.update([])
    }
}

@Suite(.serialized) @MainActor struct V042RealLibraryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LP_042_FORMAL_COPY"] != nil))
    func isolatedCurrentLibraryRelinkImportAndRealPlayback() async throws {
        let data=URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["LP_042_FORMAL_COPY"]))
        #expect(data.path.hasPrefix("/private/tmp/LecturePlayer-042-QA/"))
        let store=AppStore(root:data); #expect(!store.fatal)
        let before=try #require(store.library.lectures.first)
        let transcript=try #require(try store.repository?.read(before))
        #expect(transcript.translatedCount == 1459 && before.state.offset == 14)
        let snapshot=try Codec.decode(Backup.self,Data(contentsOf:data.appendingPathComponent("before-v07.json")))
        #expect(snapshot.transcripts.values.contains { $0 == transcript })
        store.refreshDirectory(); try await V042AppTests().wait(store)
        #expect(store.scanResult?.media.count == 6 && store.scanIssues.isEmpty)
        #expect(store.library.courses.filter { $0.directoryPath != nil }.count == 4 && store.library.folders.count == 32)
        let root=URL(fileURLWithPath:try #require(store.library.directoryRoot))
        let screen=root.appendingPathComponent("CourseA/Week8/SAMPLE1001_2026_SM2 T-s1-full.mp4")
        try await store.relinkMedia(before.id,sourceID:before.mediaSources[0].id,url:screen)
        let relinked=try #require(store.library.lectures.first { $0.id == before.id })
        #expect(relinked.state == before.state && relinked.marks == before.marks && relinked.id == before.id)
        #expect(try store.repository?.read(relinked) == transcript)
        store.current=before.id; store.transcript=transcript
        store.translation.start(store:store,ids:Set(transcript.translations.keys))
        #expect(!store.translation.running && store.translation.status.contains("没有发起请求"))
        store.current=nil; store.transcript=nil
        store.refreshDirectory(); try await V042AppTests().wait(store)
        for group in DirectoryIndex.pendingGroups(store.pendingFiles) {
            let video=try #require(group.first); let subtitles=ImportPlanner.candidates(for:video,in:store.directoryFiles)
            var row=ImportRow(video:video,subtitle:subtitles.first,title:video.deletingPathExtension().lastPathComponent)
            row.secondary=group.dropFirst().first
            try await store.importLesson(row:row,managed:false)
        }
        store.refreshDirectory(); try await V042AppTests().wait(store)
        #expect(store.library.lectures.count == 3 && store.pendingFiles.isEmpty)
        let prefs=UserDefaults(suiteName:"LP042-real-test")!; defer { prefs.removePersistentDomain(forName:"LP042-real-test") }
        let player=Playback(preferences:prefs); player.setVolume(0)
        player.load(relinked)
        for _ in 0..<400 { if player.ready { break }; try await Task.sleep(for:.milliseconds(25)) }
        #expect(player.ready && player.missing.isEmpty && !player.playing)
        #expect(abs(player.position-before.state.position)<0.15)
        var evidence:[[String:Double]]=[]
        for target in [14.0,3450.0,6800.0] {
            player.seek(target); try await Task.sleep(for:.milliseconds(400))
            let positions=player.views.map { player.player(for: $0).currentTime().seconds - $0.relativeOffset }
            #expect(positions.count == 2 && positions.allSatisfy { abs($0-target)<0.1 })
            evidence.append(["target":target,"screen":positions[0],"camera":positions[1]])
        }
        player.toggle(); try await Task.sleep(for:.seconds(2)); player.toggle()
        #expect(abs(player.player(for: player.views[0]).currentTime().seconds-player.player(for: player.views[1]).currentTime().seconds)<0.1)
        player.close()
        let reopened=try Repository(root:data).load(); let item=try #require(reopened.lectures.first { $0.id == before.id })
        #expect(item.state == before.state && item.marks == before.marks)
        #expect(try store.repository?.read(item) == transcript)
        try JSONSerialization.data(withJSONObject:["seeks":evidence,"translatedCount":transcript.translatedCount,"lessons":reopened.lectures.count,"audio":"muted; human auditory not assessed"],options:.prettyPrinted).write(to:data.appendingPathComponent("verification.json"))
    }
}
