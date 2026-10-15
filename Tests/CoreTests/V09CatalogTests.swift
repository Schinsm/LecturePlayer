import Foundation
import Testing
@testable import Core

/// Folder and title shapes taken from a real course library, with names anonymised.
struct V09CatalogTests {
    let course = UUID()
    func lesson(_ title: String, _ folder: String, week: Int? = nil, type: String? = "Lecture", position: Double = 0, duration: Double = 600) -> Lecture {
        var lesson = Lecture(title: title, courseID: course, folderID: nil, url: URL(fileURLWithPath: "/R/" + folder + "/" + title + ".mp4"), bookmark: nil, identity: title + folder)
        lesson.directoryPath = "/R/" + folder; lesson.week = week; lesson.sessionType = type
        lesson.state.position = position; lesson.duration = duration
        return lesson
    }

    @Test func weekComesFromFieldThenFolderThenTitle() {
        #expect(LessonCatalog.week(lesson("Recording W-s1-full", "COURSE/Week10")) == 10)
        #expect(LessonCatalog.week(lesson("Lecture 9.1", "COURSE/Week9/Lecture")) == 9)
        #expect(LessonCatalog.week(lesson("Recording T-s1-full", "COURSE/Week8", week: 7)) == 7)
        #expect(LessonCatalog.week(lesson("Week 11 Tutorial with Tutor Q3 - Mergers", "COURSE/Extra")) == 11)
        #expect(LessonCatalog.week(lesson("Quiz 8 solutions", "COURSE/Misc")) == nil, "a number in the title is not a week")
    }

    @Test func kindPrefersTitleThenFolderAndIgnoresTheDefaultLectureValue() {
        #expect(LessonCatalog.kind(lesson("Week 10 Tutorial with Tutor Q 1-2 - Payouts", "COURSE/Week10/Practice Questions")) == .tutorial)
        #expect(LessonCatalog.kind(lesson("Recording T-s1-full", "COURSE/Week9/Seminar")) == .seminar)
        #expect(LessonCatalog.kind(lesson("Quiz 8 solutions", "COURSE/Week9")) == .practice)
        #expect(LessonCatalog.kind(lesson("Recording T-s1-full", "COURSE/Week8", type: "Seminar")) == .seminar)
        #expect(LessonCatalog.kind(lesson("L9 Online", "COURSE/Week10")) == .lecture)
    }

    @Test func seriesStemsAndParts() {
        #expect(LessonCatalog.seriesPart("Lecture 9.3")! == ("Lecture 9", 3))
        #expect(LessonCatalog.seriesPart("Lecture 9.12 - Plug")! == ("Lecture 9", 12))
        #expect(LessonCatalog.seriesPart("Week 10 Tutorial with Tutor Q 3-4 - Payouts")! == ("Week 10 Tutorial with Tutor - Payouts", 3))
        #expect(LessonCatalog.seriesPart("Week 11 Tutorial with Tutor Q3 - Mergers")! == ("Week 11 Tutorial with Tutor - Mergers", 3))
        #expect(LessonCatalog.seriesPart("Valuation Part 2")! == ("Valuation", 2))
        #expect(LessonCatalog.seriesPart("Recording W-s1-full") == nil)
        #expect(LessonCatalog.seriesPart("L8 Online") == nil)
        #expect(LessonCatalog.seriesPart("Quiz 8 solutions") == nil)
    }

    @Test func groupsStackSeriesInPartOrderAndKeepSinglesApart() {
        let lessons = [
            lesson("Lecture 9.2", "COURSE/Week9/Lecture", position: 600),
            lesson("Lecture 9.10", "COURSE/Week9/Lecture"),
            lesson("Lecture 9.1", "COURSE/Week9/Lecture", position: 599),
            lesson("Recording T-s1-full", "COURSE/Week9/Seminar"),
            lesson("Lecture 10.1", "COURSE/Week10/Lecture"),
        ]
        let groups = LessonCatalog.groups(lessons)
        let series = groups.first { $0.isSeries }!
        #expect(series.title == "Lecture 9")
        #expect(series.lessons.map(\.title) == ["Lecture 9.1", "Lecture 9.2", "Lecture 9.10"])
        #expect(series.watchedCount == 2)
        #expect(series.next?.title == "Lecture 9.10")
        #expect(groups.count == 3, "Lecture 10.1 is alone in its week, so it is not stacked")
        #expect(groups.last?.kind == .seminar)
    }

    @Test func partLabelsUseNumbersOnlyForDottedSeries() {
        let dotted = LessonCatalog.groups([lesson("Lecture 9.1", "C/Week9/Lecture"), lesson("Lecture 9.4", "C/Week9/Lecture")])[0]
        #expect(dotted.partRange == "9.1–9.4")
        #expect(dotted.partLabel(dotted.lessons[1]) == "9.4")
        let tutorial = LessonCatalog.groups([lesson("Week 10 Tutorial with Tutor Q 1-2 - Payouts", "C/Week10/Practice Questions"),
                                             lesson("Week 10 Tutorial with Tutor Q 3-4 - Payouts", "C/Week10/Practice Questions")])[0]
        #expect(tutorial.partRange == nil)
        #expect(tutorial.partLabel(tutorial.lessons[1]) == "第 2 段")
    }

    @Test func captureExportNamesReadAsWeekRecordings() {
        #expect(LessonCatalog.displayTitle(lesson("FNCE90018_2026_SM2 W-s1-full", "C/Week10")) == "Week 10 录像")
        #expect(LessonCatalog.displayTitle(lesson("ACCT90002_2026_SM2 T-s1-full", "C/Week9/Seminar")) == "Week 9 Seminar 录像")
        #expect(LessonCatalog.displayTitle(lesson("ACCT90002_2026_SM2 F-s1-full", "C/Misc")) == "录像")
        #expect(LessonCatalog.displayTitle(lesson("Lecture 9.1", "C/Week9/Lecture")) == "Lecture 9.1")
        var custom = lesson("FNCE90018_2026_SM2 W-s1-full", "C/Week10"); custom.customTitle = false; custom.topic = "Payout policy"
        #expect(LessonCatalog.displayTitle(custom) == custom.displayTitle, "metadata the user set wins")
    }

    @Test func shortTitlesAndCaptureOffsets() {
        #expect(LessonCatalog.shortTitle(lesson("FNCE90018_2026_SM2 W-s1-full", "C/Week10")) == "课堂录像")
        #expect(LessonCatalog.shortTitle(lesson("ACCT90002_2026_SM2 T-s1-full", "C/Week9/Seminar")) == "Seminar 录像")
        #expect(LessonCatalog.shortTitle(lesson("L9 Online", "C/Week10")) == "L9 Online")
        #expect(LessonCatalog.defaultSubtitleOffset(title: "FNCE90018_2026_SM2 W-s1-full") == 14)
        #expect(LessonCatalog.defaultSubtitleOffset(title: "Lecture 9.1") == 0)
        var adjusted = lesson("FNCE90018_2026_SM2 W-s1-full", "C/Week10"); adjusted.state.subtitleOffsetSeconds = 12.5
        #expect(!LessonCatalog.needsCaptureOffset(adjusted), "a value the user set is kept")
        #expect(LessonCatalog.needsCaptureOffset(lesson("FNCE90018_2026_SM2 W-s1-full", "C/Week10")))
        #expect(!LessonCatalog.needsCaptureOffset(lesson("Lecture 9.1", "C/Week9/Lecture")))
    }

    @Test func sectionsAreNewestFirstWithUnknownWeekLast() {
        let sections = LessonCatalog.sections([
            lesson("Recording", "COURSE/Week8"), lesson("Loose", "COURSE/Misc"),
            lesson("Lecture 11.1", "COURSE/Week11/Lecture"), lesson("Lecture 11.2", "COURSE/Week11/Lecture"),
        ])
        #expect(sections.map(\.week) == [11, 8, nil])
        #expect(sections[0].groups.count == 1 && sections[0].groups[0].lessons.count == 2)
    }

    @Test func differentCoursesOrKindsNeverShareASeries() {
        var other = lesson("Lecture 9.2", "OTHER/Week9/Lecture"); other.courseID = UUID()
        let groups = LessonCatalog.groups([lesson("Lecture 9.1", "COURSE/Week9/Lecture"), other])
        #expect(groups.allSatisfy { !$0.isSeries })
    }
}

/// 0.9.1 resend rule: only answers that cost nothing are retried, at most three times.
struct V091RetryPolicyTests {
    @Test func onlyRateLimitsServerErrorsAndLostConnectionsAreResent() {
        #expect(RetryPolicy.delay(status: 429, retryAfter: 7, attempt: 0) == 7)
        #expect(RetryPolicy.delay(status: 503, attempt: 0) == 2)
        #expect(RetryPolicy.delay(status: 502, attempt: 2) == 8)
        #expect(RetryPolicy.delay(status: 429, attempt: 3) == nil, "three resends at most")
        #expect(RetryPolicy.delay(status: 401, attempt: 0) == nil)
        #expect(RetryPolicy.delay(status: 400, attempt: 0) == nil)
        #expect(RetryPolicy.delay(status: nil, urlError: .networkConnectionLost, attempt: 0) == 2)
        #expect(RetryPolicy.delay(status: nil, urlError: .timedOut, attempt: 0) == nil, "a timed-out request may have been billed")
        #expect(RetryPolicy.delay(for: APIError(status: 429, retryable: false), attempt: 0) == nil, "exhausted quota")
        #expect(RetryPolicy.delay(status: 429, retryAfter: 600, attempt: 0) == 60, "waits are capped")
    }
}
