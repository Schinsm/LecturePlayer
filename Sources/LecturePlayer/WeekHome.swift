import SwiftUI
import Core

/// Status filters on the week page. Raw values are stored in UserDefaults.
enum WeekStatusFilter: String, CaseIterable, Identifiable {
    case all = "", unwatched, noSubtitle, noChapters
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "全部"; case .unwatched: "未看完"; case .noSubtitle: "无字幕"; case .noChapters: "未生成章节"
        }
    }
    var icon: String {
        switch self {
        case .all: "square.grid.2x2.fill"; case .unwatched: "play.fill"; case .noSubtitle: "waveform"; case .noChapters: "list.bullet"
        }
    }
    var tint: Color {
        switch self {
        case .all: .secondary; case .unwatched: .accentColor; case .noSubtitle: CourseColor.orange.color; case .noChapters: CourseColor.purple.color
        }
    }
}

/// Home page: one week at a time, grouped by course, with series stacked.
struct WeekHome: View {
    let store: AppStore
    @ObservedObject private var navigation: DirectoryPresentation
    @ObservedObject private var statuses: LessonStatusPresentation
    @ObservedObject private var analysis: AnalysisJob
    @AppStorage("weekHome.course") private var courseFilter = ""
    @AppStorage("weekHome.kind") private var kindFilter = ""
    @AppStorage("weekHome.status") private var statusFilter = WeekStatusFilter.all
    @LPState private var chosenWeek: Int??
    /// This week's videos that are still only in the cloud folder.
    @LPState private var cloudVideos: [URL] = []
    @LPState private var prefetching = false
    init(store: AppStore) {
        self.store = store
        navigation = store.navigation; statuses = store.lessonStatuses; analysis = store.analysis
    }

    private var courses: [Course] { navigation.index.courses }
    private var lessons: [Lecture] {
        let ids = Set(courses.map(\.id))
        return store.library.lectures.filter { $0.archived != true && $0.directoryPath != nil && ids.contains($0.courseID) }
    }
    private var sections: [WeekSection] { LessonCatalog.sections(lessons) }
    /// The week of the last lesson studied, else the newest week.
    private var defaultWeek: Int? {
        if let last = store.library.lastLecture, let lesson = lessons.first(where: { $0.id == last }), let week = LessonCatalog.week(lesson) { return week }
        return sections.first?.week
    }
    private var week: Int? { chosenWeek ?? defaultWeek }
    private var current: WeekSection? { sections.first { $0.week == week } }
    private var weekNumbers: [Int?] { sections.map(\.week) }

    private func matches(_ lesson: Lecture, _ filter: WeekStatusFilter) -> Bool {
        switch filter {
        case .all: true
        case .unwatched: !LessonCatalog.isWatched(lesson)
        case .noSubtitle: lesson.transcriptVersion == nil
        case .noChapters: lesson.transcriptVersion != nil && statuses.analysis(lesson, job: analysis)?.complete != true
        }
    }
    private func visible(_ group: LessonGroup) -> Bool {
        (courseFilter.isEmpty || group.courseID.uuidString == courseFilter)
            && (kindFilter.isEmpty || group.kind.rawValue == kindFilter)
            && group.lessons.contains { matches($0, statusFilter) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let current {
                    statusCards(current)
                    filters
                    courseGrid(current)
                } else {
                    ContentUnavailableView("还没有课件", systemImage: "calendar", description: Text("在设置的资料库页面选择课程总目录，导入后按周显示。"))
                        .frame(maxWidth: .infinity, minHeight: 320)
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: week) {
            prefetching = false
            cloudVideos = await Self.onlineOnly(current?.lessons ?? [])
            for lesson in current?.lessons ?? [] { await statuses.prepare(lesson, repository: store.repository) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Button { step(1) } label: { Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 30, height: 30) }
                .disabled(index(of: week).map { $0 + 1 >= weekNumbers.count } ?? true).help("上一周").accessibilityLabel("上一周")
            Text(weekTitle(week)).font(.largeTitle.bold()).monospacedDigit()
            Button { step(-1) } label: { Image(systemName: "chevron.right").font(.title3.weight(.semibold)).frame(width: 30, height: 30) }
                .disabled(index(of: week).map { $0 == 0 } ?? true).help("下一周").accessibilityLabel("下一周")
            Spacer()
            if !cloudVideos.isEmpty {
                Button { Task { await prefetch() } } label: {
                    Label(prefetching ? "正在下载 \(cloudVideos.count) 个视频" : "预下载本周", systemImage: "icloud.and.arrow.down")
                        .font(.callout).padding(.horizontal, 12).frame(height: 30).glassSurface(Capsule())
                }
                .disabled(prefetching)
                .help("把本周 \(cloudVideos.count) 个只在云端的视频下载到这台 Mac，打开时无需等待")
            }
            if chosenWeek != nil {
                Button { chosenWeek = nil } label: { Label("回到最近学习的一周", systemImage: "clock.arrow.circlepath").labelStyle(.iconOnly).frame(width: 30, height: 30) }
                    .help("回到最近学习的一周")
            }
        }.buttonStyle(.plain)
    }
    /// Checked off the main thread: one lstat per video, which never downloads anything.
    static func onlineOnly(_ lessons: [Lecture]) async -> [URL] {
        let paths = lessons.flatMap { $0.mediaSources.map(\.path) }
        return await Task.detached(priority: .utility) { paths.map { URL(fileURLWithPath: $0) }.filter(CloudFile.isOnlineOnly) }.value
    }
    /// The cloud app keeps downloading in the background; the button disappears when all are local.
    private func prefetch() async {
        prefetching = true
        for url in cloudVideos { CloudFile.requestDownload(url) }
        while prefetching, !cloudVideos.isEmpty, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            let remaining = cloudVideos
            cloudVideos = await Task.detached(priority: .utility) { remaining.filter(CloudFile.isOnlineOnly) }.value
        }
        prefetching = false
    }
    private func weekTitle(_ week: Int?) -> String { week.map { "Week \($0)" } ?? "未分周" }
    private func index(of week: Int?) -> Int? { weekNumbers.firstIndex { $0 == week } }
    /// Sections run newest first, so "previous week" is the next index.
    private func step(_ offset: Int) {
        guard let i = index(of: week), weekNumbers.indices.contains(i + offset) else { return }
        chosenWeek = .some(weekNumbers[i + offset])
    }

    // MARK: Filters

    private func statusCards(_ section: WeekSection) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            ForEach(WeekStatusFilter.allCases) { filter in
                let count = section.lessons.filter { matches($0, filter) }.count
                let selected = statusFilter == filter
                Button { statusFilter = selected && filter != .all ? .all : filter } label: {
                    HStack(spacing: 12) {
                        Image(systemName: filter.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 30, height: 30).background(filter == .all ? Color.secondary.opacity(0.5) : filter.tint, in: Circle())
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(count)").font(.title2.bold()).monospacedDigit()
                            Text(filter.title).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16).frame(height: 70).contentShape(Rectangle())
                    .overlay { if selected { RoundedRectangle(cornerRadius: 18).stroke(Color.accentColor, lineWidth: 1.5) } }
                }
                .buttonStyle(.plain).glassSurface(RoundedRectangle(cornerRadius: 18), interactive: true)
                .accessibilityLabel(filter.title + "，\(count) 项").accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 12) {
            chips(label: "课程", options: [("", "全部", nil)] + courses.map { ($0.id.uuidString, $0.name, store.courseColor($0.id).color) }, selection: $courseFilter)
            chips(label: "类型", options: [("", "全部", nil)] + SessionKind.allCases.map { ($0.rawValue, $0.rawValue, nil) }, selection: $kindFilter)
            Spacer(minLength: 0)
        }
    }
    private func chips(label: String, options: [(String, String, Color?)], selection: Binding<String>) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title, dot in
                let on = selection.wrappedValue == value
                Button { selection.wrappedValue = value } label: {
                    HStack(spacing: 6) {
                        if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                        Text(title).font(.callout.weight(on ? .semibold : .regular))
                    }
                    .padding(.horizontal, 11).frame(height: 26)
                    .background { if on { Capsule().fill(Color.primary.opacity(0.14)) } }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain).foregroundStyle(on ? .primary : .secondary)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3).glassSurface(Capsule()).accessibilityElement(children: .contain).accessibilityLabel(label)
    }

    // MARK: Courses

    private func courseGrid(_ section: WeekSection) -> some View {
        let byCourse = courses.compactMap { course -> (Course, [LessonGroup])? in
            let groups = section.groups.filter { $0.courseID == course.id && visible($0) }
            return groups.isEmpty ? nil : (course, groups)
        }
        return Group {
            if byCourse.isEmpty {
                VStack(spacing: 6) {
                    Text("本周没有符合条件的课件").font(.headline)
                    Text("换一个筛选条件，或切换到其他周。").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(40).glassSurface(RoundedRectangle(cornerRadius: 20))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 520), spacing: 28, alignment: .top)], alignment: .leading, spacing: 24) {
                    ForEach(byCourse, id: \.0.id) { course, groups in
                        VStack(alignment: .leading, spacing: 10) {
                            CourseHeading(name: course.name, color: store.courseColor(course.id).color) { navigation.select(course: course.id) }
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 16) {
                                    ForEach(groups) { LessonGroupCard(store: store, group: $0, statuses: statuses, analysis: analysis) }
                                }.padding(.top, 8).padding(.bottom, 4)
                            }
                        }
                    }
                }
            }
        }
    }

}

/// A lesson or a stacked series on the week page.
struct LessonGroupCard: View {
    let store: AppStore
    let group: LessonGroup
    @ObservedObject var statuses: LessonStatusPresentation
    @ObservedObject var analysis: AnalysisJob
    private var color: Color { store.courseColor(group.courseID).color }
    private var lead: Lecture { group.next ?? group.lessons[0] }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
        Button { store.open(lead.id) } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack(alignment: .top) {
                    if group.isSeries {
                        RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.4)).frame(width: 212, height: 30).offset(y: -10)
                        RoundedRectangle(cornerRadius: 13).fill(color.opacity(0.7)).frame(width: 230, height: 30).offset(y: -5)
                    }
                    ZStack {
                        LinearGradient(colors: [color.opacity(0.9), color.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        LessonThumbnail(lesson: lead, width: 248, height: 140, radius: 14)
                    }
                    .frame(width: 248, height: 140).clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(alignment: .topLeading) {
                        if fraction >= 1 {
                            Image(systemName: "checkmark.circle.fill").font(.title3).symbolRenderingMode(.palette)
                                .foregroundStyle(.white, CourseColor.green.color).padding(8).accessibilityHidden(true)
                        } else if group.isSeries { badge("\(group.lessons.count) 段") }
                    }
                    .overlay(alignment: .topTrailing) { if let length { badge(length) } }
                    .overlay(alignment: .bottom) { progress.padding(10) }
                }
                .padding(.top, 10)
                Text(group.isSeries ? group.title : LessonCatalog.shortTitle(lead)).font(.headline).lineLimit(1).help(lead.title)
            }
            .frame(width: 248, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel((group.isSeries ? group.title + "，\(group.lessons.count) 段" : LessonCatalog.displayTitle(lead)) + "，" + progressText)
        // Outside the open button, so the transcribe action inside it stays clickable.
        detail.frame(width: 248, alignment: .leading)
        }
        .contextMenu {
            if group.isSeries {
                ForEach(group.lessons) { lesson in Button("播放 " + lesson.title) { store.open(lesson.id) } }
            }
            Button("在课程页查看") { store.navigation.select(course: group.courseID) }
        }
    }
    private var length: String? {
        if group.isSeries { return group.lessons.allSatisfy { $0.duration > 0 } ? "共 " + timeLabel(group.lessons.reduce(0) { $0 + $1.duration }) : nil }
        return lead.duration > 0 ? timeLabel(lead.duration) : nil
    }
    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3).background(.black.opacity(0.35), in: Capsule()).padding(8)
    }
    private var fraction: Double {
        if group.isSeries { return Double(group.watchedCount) / Double(group.lessons.count) }
        if LessonCatalog.isWatched(lead) { return 1 }
        return lead.duration > 0 ? min(1, lead.state.position / lead.duration) : 0
    }
    @ViewBuilder private var progress: some View {
        if fraction > 0 && fraction < 1 && !group.isSeries {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3))
                    Capsule().fill(.white).frame(width: proxy.size.width * fraction)
                }
            }.frame(height: 4)
        }
    }
    private var progressText: String {
        if group.isSeries {
            let next = group.watchedCount < group.lessons.count ? " · 下一段 " + lead.title : ""
            return group.watchedCount == group.lessons.count ? "已看完 \(group.lessons.count)/\(group.lessons.count)" : "已看 \(group.watchedCount)/\(group.lessons.count)" + next
        }
        if LessonCatalog.isWatched(lead) { return "已看完" }
        return fraction > 0 ? "已看 \(Int(fraction * 100))%" : "未开始"
    }
    private var detail: some View {
        HStack(spacing: 6) {
            if group.isSeries { SeriesSegments(lessons: group.lessons) }
            if let bare = group.lessons.first(where: { $0.transcriptVersion == nil }) {
                Text("无字幕").font(.caption2.weight(.semibold)).foregroundStyle(CourseColor.orange.color)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(CourseColor.orange.color.opacity(0.18), in: Capsule())
                TranscribeControl(store: store, lessonID: bare.id, compact: true)
            } else if group.lessons.contains(where: { statuses.analysis($0, job: analysis)?.complete != true }) && statuses.analysisLoaded {
                Text("未生成章节").font(.caption2.weight(.semibold)).foregroundStyle(CourseColor.purple.color)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(CourseColor.purple.color.opacity(0.18), in: Capsule())
            }
        }.font(.caption)
    }
}

struct ProgressRing: View {
    let value: Double
    var body: some View {
        ZStack {
            if value >= 1 {
                Circle().fill(CourseColor.green.color)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            } else {
                Circle().stroke(Color.primary.opacity(0.15), lineWidth: 3)
                Circle().trim(from: 0, to: value).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityLabel(value >= 1 ? "已全部看完" : "已看 \(Int(value * 100))%")
    }
}

/// One short bar per part: green watched, accent started, grey not started.
struct SeriesSegments: View {
    let lessons: [Lecture]
    var width: CGFloat = 18
    var body: some View {
        HStack(spacing: 3) {
            ForEach(lessons) { part in
                Capsule().fill(LessonCatalog.isWatched(part) ? CourseColor.green.color : part.state.position > 0 ? Color.accentColor : Color.primary.opacity(0.15))
                    .frame(width: width, height: 4)
            }
        }.accessibilityHidden(true)
    }
}

/// Course name as a quiet link to its course page; a chevron appears on hover.
private struct CourseHeading: View {
    let name: String
    let color: Color
    let open: () -> Void
    @LPState private var hovering = false
    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(name).font(.title3.weight(.semibold))
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary).opacity(hovering ? 1 : 0)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .help("打开课程页").accessibilityLabel(name + "，打开课程页")
    }
}
