import Foundation
import SwiftUI
import AppKit
import Testing
@testable import Core
@testable import LecturePlayer

@MainActor @Suite(.serialized) struct V085AppTests {
    @Test func collapseKeepsHostedViewsAndWidthWithoutSavingCollapsedRatio() {
        _=NSApplication.shared
        let split=StudySplit<Text,Text>.Split(frame:NSRect(x:0,y:0,width:1200,height:700))
        split.isVertical=true;split.delegate=split
        let left=NSView(),right=NSView();split.addArrangedSubview(left);split.addArrangedSubview(right)
        split.layout();split.setPosition(700,ofDividerAt:0);let width=left.frame.width
        for _ in 0..<5 {
            split.setRightVisible(false)
            #expect(right.isHidden && split.arrangedSubviews.count==2)
            #expect(left.frame.width>1100)
            #expect(split.dividerThickness==0 && left.frame==split.bounds)
            #expect(split.splitView(split,shouldHideDividerAt:0))
            #expect(split.splitView(split,effectiveRect:NSRect(x:700,y:0,width:1,height:700),forDrawnRect:.zero,ofDividerAt:0).isEmpty)
            split.frame.size.width=1400;split.layout()
            #expect(left.frame==split.bounds)
            split.frame.size.width=1200;split.layout()
            split.setRightVisible(true)
            #expect(split.dividerThickness>0)
            #expect(!right.isHidden && split.arrangedSubviews[1] === right)
            #expect(abs(left.frame.width-width)<2)
        }
    }
    @Test func newlyCreatedDeepHiddenMediaAppearsThroughWatcher()async throws {
        let data=try V042AppTests().root(),media=data.appendingPathComponent("Recordings"),week=media.appendingPathComponent("CourseA/Week9")
        try FileManager.default.createDirectory(at:week,withIntermediateDirectories:true)
        let store=AppStore(root:data);store.library.directoryRoot=media.path;store.watchesEnabled=true
        defer{store.directoryWatch.update([]);try? FileManager.default.removeItem(at:data)}
        store.refreshDirectory();try await V042AppTests().wait(store)
        let folder=week.appendingPathComponent("Lecture/Part"),file=folder.appendingPathComponent("Lecture 9.1.mp4")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);try Data("mock video".utf8).write(to:file)
        var values=URLResourceValues();values.isHidden=true;var u=file;try u.setResourceValues(values)
        for _ in 0..<200 {if store.pendingFiles.count==1 {break};try await Task.sleep(for:.milliseconds(30))}
        #expect(store.pendingFiles.count==1 && store.navigation.index.pending.count==1)
        #expect(store.library.folders.contains{$0.name=="Part"})
        #expect(!store.translation.running && !store.analysis.running && store.library.lectures.isEmpty)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP085_ISOLATED"]=="1"))
    func latestIsolatedLibraryRoundTripPreservesAllStudyData()async throws {
        let root=URL(fileURLWithPath:"/private/tmp/LP085/data"),repo=try Repository(root:root)
        let snapshot=root.appendingPathComponent("qa085-"+UUID().uuidString+".json")
        let before=try repo.load(),analyses=try AnalysisRepository.readAll(root:root)
        let transcripts=try before.lectures.compactMap{try repo.read($0)}
        try repo.writeRecoverySnapshot(before,to:snapshot)
        try repo.save(before)
        #expect(try Repository(root:root).load()==before)
        #expect(try AnalysisRepository.readAll(root:root)==analyses)
        #expect(try before.lectures.compactMap{try repo.read($0)}==transcripts)
        let backup=try Codec.decode(Backup.self,Data(contentsOf:snapshot))
        try backup.validate()
        #expect(backup.library.lectures.map(\.state)==before.lectures.map(\.state))
    }
}
