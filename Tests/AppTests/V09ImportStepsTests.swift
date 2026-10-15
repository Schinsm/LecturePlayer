import Foundation
import Testing
@testable import LecturePlayer

/// 0.9 merges the two import checkboxes into one switch; each row states what will happen to it.
struct V09ImportStepsTests {
    @Test func newRowWithSubtitleGetsBothStepsInOrder() {
        let plan=ImportStepPlan.make(existing:false,hasSubtitle:true,translation:.ready,chapters:.ready)
        #expect(plan.steps == [.translate,.chapters])
        #expect(plan.label == "翻译 → 生成章节")
    }

    @Test func stepsTurnedOffInSettingsAreLeftOutSilently() {
        let plan=ImportStepPlan.make(existing:false,hasSubtitle:true,translation:.disabled,chapters:.ready)
        #expect(plan.steps == [.chapters])
        #expect(plan.note.isEmpty)
        let none=ImportStepPlan.make(existing:false,hasSubtitle:true,translation:.disabled,chapters:.disabled)
        #expect(none.steps.isEmpty)
        #expect(none.label == "设置中未选择处理步骤，只导入")
    }

    @Test func unavailableStepIsSkippedWithItsReasonOnTheRow() {
        let plan=ImportStepPlan.make(existing:false,hasSubtitle:true,translation:.unavailable("DeepL 未就绪"),chapters:.ready)
        #expect(plan.steps == [.chapters])
        #expect(plan.label == "生成章节（翻译：DeepL 未就绪）")
    }

    @Test func rowsWithoutSubtitleOrRelinkedRowsAreOnlyImported() {
        let bare=ImportStepPlan.make(existing:false,hasSubtitle:false,translation:.ready,chapters:.ready)
        #expect(bare.steps.isEmpty && bare.label.hasPrefix("没有字幕"))
        let relink=ImportStepPlan.make(existing:true,hasSubtitle:true,translation:.ready,chapters:.ready)
        #expect(relink.steps.isEmpty && relink.label == "关联原课件，不重新处理")
    }
}

/// The top-bar 章节 / 转写 switches are the one place to show or hide reading columns.
@MainActor struct V09ReadingSwitchTests {
    @Test func switchesHideEachColumnAndReopenOnlyTheOneAsked() throws {
        let defaults=try #require(UserDefaults(suiteName:"v09-switch-\(UUID())"))
        let columns=ReadingColumns(defaults:defaults)
        #expect(columns.isOn(.chapters) && columns.isOn(.transcript))
        columns.toggle(.chapters)
        #expect(!columns.isOn(.chapters) && columns.isOn(.transcript))
        columns.toggle(.transcript)
        #expect(!columns.isOn(.chapters) && !columns.isOn(.transcript) && !columns.value.enabled)
        columns.toggle(.chapters)
        #expect(columns.isOn(.chapters) && !columns.isOn(.transcript), "reopening one column must not bring back the other")
        columns.toggle(.transcript)
        #expect(columns.isOn(.chapters) && columns.isOn(.transcript))
    }
}

/// 0.9.1: Lecture Capture recordings still at 0 s get +14 s once; values the user set are kept.
@MainActor struct V091CaptureOffsetTests {
    @Test func migrationRunsOnceAndOnlyTouchesZeroCaptureRecordings() throws {
        let (root,fixture,transcript)=try PersistenceTests().fixture()
        defer {try? FileManager.default.removeItem(at:root)}
        var library=fixture
        var capture=library.lectures[0];capture.id=UUID();capture.title="FNCE90018_2026_SM2 W-s1-full";capture.identity="capture"
        var tuned=capture;tuned.id=UUID();tuned.identity="tuned";tuned.state.subtitleOffsetSeconds=12.5
        library.lectures[0].title="Lecture 9.1"
        library.lectures+=[capture,tuned]
        do {let repository=try Repository(root:root);for lesson in library.lectures {try repository.write(transcript,for:lesson.id)};try repository.save(library)}
        let store=AppStore(root:root)
        #expect(store.error==nil)
        func offset(_ id:UUID,_ s:AppStore)->Double {s.library.lectures.first{$0.id==id}!.state.subtitleOffsetSeconds}
        #expect(offset(capture.id,store)==14)
        #expect(offset(tuned.id,store)==12.5)
        #expect(offset(library.lectures[0].id,store)==0)
        #expect(store.library.appliedMigrations?.contains("capture-offset-14")==true)
        #expect(try FileManager.default.contentsOfDirectory(atPath:root.path).contains{$0.hasPrefix("before-v091-offset-")})
        // A later deliberate 0 is not overwritten on the next launch.
        store.updateLecture(capture.id){$0.state.subtitleOffsetSeconds=0};store.flushMetadata()
        let reopened=AppStore(root:root)
        #expect(offset(capture.id,reopened)==0)
    }
}
