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
