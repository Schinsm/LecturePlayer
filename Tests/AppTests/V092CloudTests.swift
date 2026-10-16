import Foundation
import Testing
import Core
@testable import LecturePlayer

/// Stands in for Google Drive: named files in one test folder are placeholders until "downloaded".
/// Starting a download publishes file progress the way the provider does, then completes after `steps`.
private final class FakeDrive: @unchecked Sendable {
    let token = "lp-cloud-\(UUID().uuidString)"
    private let lock = NSLock()
    private var cloud: Set<String>
    private(set) var started: [String] = []
    var steps: [Double] = [0.5]      // progress values published before the file becomes local
    var stepDelay: UInt64 = 400_000_000
    var completes = true
    private var published: [Progress] = []
    init(cloud: Set<String>) { self.cloud = cloud }

    func isCloud(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return cloud.contains(name) }
    func makeLocal(_ name: String) { lock.lock(); cloud.remove(name); lock.unlock() }
    var simulation: CloudFile.Simulation {
        CloudFile.Simulation(isOnlineOnly: { [self] url in url.path.contains(token) ? isCloud(url.lastPathComponent) : nil },
                             startDownload: { [self] url in start(url) })
    }
    private func start(_ url: URL) {
        lock.lock(); started.append(url.lastPathComponent); lock.unlock()
        let progress = Progress(totalUnitCount: 100)
        progress.kind = .file; progress.fileOperationKind = .downloading
        progress.setUserInfoObject(url, forKey: .fileURLKey); progress.publish()
        lock.lock(); published.append(progress); lock.unlock()
        let steps = steps, delay = stepDelay, completes = completes, name = url.lastPathComponent
        Task.detached { [self] in
            for value in steps { progress.completedUnitCount = Int64(value * 100); try? await Task.sleep(nanoseconds: delay) }
            guard completes else { return }
            progress.completedUnitCount = 100; makeLocal(name); progress.unpublish()
        }
    }
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(token, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func finish() { CloudFile.simulation = nil; lock.lock(); published.forEach { $0.unpublish() }; lock.unlock() }
}

private let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Samples/Synthetic.mp4")

private struct InstantEngine: TranscriptionEngine {
    func transcribe(_ media: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedText] {
        [TimedText(start: 0, end: 1.5, text: "From the cloud.")]
    }
}

/// 0.9.2: courses can live in a Google Drive folder whose videos stay online-only until they are needed.
@Suite(.serialized) @MainActor struct V092CloudTests {
    @Test func scanListsOnlineOnlyVideosWithoutDownloadingThemAndFetchesSubtitles() async throws {
        let drive = FakeDrive(cloud: ["Lecture 1.mp4", "Lecture 1.vtt"]); CloudFile.simulation = drive.simulation
        defer { drive.finish() }
        let root = try drive.folder(); defer { try? FileManager.default.removeItem(at: root) }
        let week = root.appendingPathComponent("FNCE/Week 1", isDirectory: true)
        try FileManager.default.createDirectory(at: week, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sample, to: week.appendingPathComponent("Lecture 1.mp4"))
        try Data("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHi.\n".utf8).write(to: week.appendingPathComponent("Lecture 1.vtt"))
        drive.stepDelay = 50_000_000
        let cache = MediaFingerprintCache()
        let result = try await DirectoryScanner(cache: cache).scan(root, settle: .milliseconds(10))
        #expect(result.issues.isEmpty, "\(result.issues)")
        #expect(result.media.count == 1 && result.media[0].hash == nil)
        #expect(await cache.hashReads == 0, "hashing would have downloaded the video")
        #expect(result.files.map(\.lastPathComponent).contains("Lecture 1.vtt"))
        #expect(drive.started == ["Lecture 1.vtt"])
    }

    @Test func openingAnOnlineOnlyLessonDownloadsWithProgressThenPlays() async throws {
        let drive = FakeDrive(cloud: ["Tutorial.mp4"]); CloudFile.simulation = drive.simulation
        drive.steps = [0.25, 0.5]; drive.stepDelay = 700_000_000  // long enough to observe under a loaded test run
        defer { drive.finish() }
        let folder = try drive.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appendingPathComponent("Tutorial.mp4"); try FileManager.default.copyItem(at: sample, to: video)
        let lesson = Lecture(title: "Tutorial", courseID: UUID(), folderID: nil, url: video, bookmark: nil, identity: "cloud")
        let playback = Playback(); playback.player.isMuted = true
        playback.load(lesson)
        var seen: [Double] = []
        for _ in 0..<300 {
            if let value = playback.cloudDownload { seen.append(value) }
            if playback.ready || playback.error != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(playback.error == nil); #expect(playback.ready)
        #expect(seen.contains { $0 >= 0.4 && $0 < 1 }, "progress seen: \(Set(seen).sorted())")
        #expect(playback.cloudDownload == nil)
        playback.close()
    }

    @Test func cancellingTheDownloadLeavesTheLessonClosedAndRetryWorks() async throws {
        let drive = FakeDrive(cloud: ["Seminar.mp4"]); drive.completes = false; CloudFile.simulation = drive.simulation
        defer { drive.finish() }
        let folder = try drive.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appendingPathComponent("Seminar.mp4"); try FileManager.default.copyItem(at: sample, to: video)
        let lesson = Lecture(title: "Seminar", courseID: UUID(), folderID: nil, url: video, bookmark: nil, identity: "cloud")
        let playback = Playback(); playback.player.isMuted = true
        playback.load(lesson)
        for _ in 0..<40 { if playback.cloudDownload != nil { break }; try await Task.sleep(nanoseconds: 25_000_000) }
        try #require(playback.cloudDownload != nil)
        playback.cancelCloudDownload()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(playback.cloudDownload == nil && !playback.ready)
        #expect(playback.error?.hasPrefix("已取消下载") == true)
        // The cloud app finishes later; retrying opens it.
        drive.makeLocal("Seminar.mp4")
        playback.retryLoad(lesson)
        for _ in 0..<100 { if playback.ready || playback.error?.hasPrefix("已取消") == false { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(playback.ready && playback.error == nil)
        playback.close()
    }

    @Test func aDownloadThatMakesNoProgressFails() async throws {
        let drive = FakeDrive(cloud: ["Stuck.mp4"]); drive.steps = []; drive.completes = false; CloudFile.simulation = drive.simulation
        defer { drive.finish() }
        let file = try drive.folder().appendingPathComponent("Stuck.mp4")
        await #expect(throws: Failure.self) { try await CloudFile.download(file, stall: 0.3, poll: .milliseconds(50)) }
    }

    @Test func previewsAndTheWeekCheckDoNotTouchCloudVideos() async throws {
        let drive = FakeDrive(cloud: ["Week 3.mp4"]); CloudFile.simulation = drive.simulation
        defer { drive.finish() }
        let folder = try drive.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let cloudVideo = folder.appendingPathComponent("Week 3.mp4"); try FileManager.default.copyItem(at: sample, to: cloudVideo)
        let cloudLesson = Lecture(title: "Week 3", courseID: UUID(), folderID: nil, url: cloudVideo, bookmark: nil, identity: "a")
        let localLesson = Lecture(title: "Local", courseID: UUID(), folderID: nil, url: sample, bookmark: nil, identity: "b")
        let renderer = ThumbnailRenderer(root: folder.appendingPathComponent("thumbs"))
        await #expect(throws: OnlineOnly.self) { _ = try await renderer.image(ThumbnailRequest(source: cloudLesson.mediaSources[0])) }
        #expect(await WeekHome.onlineOnly([cloudLesson, localLesson]).map(\.lastPathComponent) == ["Week 3.mp4"])
        #expect(drive.started.isEmpty)
        // Once the cloud app has fetched it (opened elsewhere or pre-downloaded), the preview renders.
        #expect(await ThumbnailRenderer.stillInCloud(cloudVideo.path))
        drive.makeLocal("Week 3.mp4")
        #expect(await !ThumbnailRenderer.stillInCloud(cloudVideo.path))
        let image = try await renderer.image(ThumbnailRequest(source: cloudLesson.mediaSources[0]))
        #expect(FileManager.default.fileExists(atPath: image.path))
    }

    @Test func transcribingAnOnlineOnlyLessonDownloadsItFirst() async throws {
        let (root, fixture, _) = try PersistenceTests().fixture()
        let drive = FakeDrive(cloud: ["Tutorial 4.mp4"]); CloudFile.simulation = drive.simulation
        defer { drive.finish(); try? FileManager.default.removeItem(at: root) }
        let course = try drive.folder().appendingPathComponent("Course", isDirectory: true)
        try FileManager.default.createDirectory(at: course, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: course.deletingLastPathComponent()) }
        let video = course.appendingPathComponent("Tutorial 4.mp4"); try FileManager.default.copyItem(at: sample, to: video)
        var library = fixture; library.lectures[0].path = video.path; library.lectures[0].mediaSources[0].path = video.path; library.lectures[0].transcriptVersion = nil
        try Repository(root: root).save(library)
        let store = AppStore(root: root), id = store.library.lectures[0].id
        store.transcription.engine = InstantEngine()
        store.transcription.enqueue([id], store: store)
        var sawDownload = false
        for _ in 0..<100 {
            sawDownload = sawDownload || store.transcription.downloading
            if store.transcription.current == nil && !store.transcription.isQueuedAny { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // The store also reopens the last lesson at launch, which requests the same file.
        #expect(sawDownload && Set(drive.started) == ["Tutorial 4.mp4"], "started \(drive.started)")
        #expect(store.library.lectures[0].transcriptSource == .appleSpeech)
    }
}

/// Real Google Drive placeholder; opt in with LP_DRIVE_FILE=<an online-only file in the Drive folder>.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LP_DRIVE_FILE"] != nil))
func realDrivePlaceholderDownloadsWithProgress() async throws {
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LP_DRIVE_FILE"]!)
    try #require(CloudFile.isOnlineOnly(url), "pick a file that is not downloaded yet")
    let values = ProgressValues(), started = Date()
    try await CloudFile.download(url) { value in Task { await values.add(value) } }
    try await Task.sleep(nanoseconds: 100_000_000)
    print("V092 DRIVE \(url.lastPathComponent): \(String(format: "%.1f", Date().timeIntervalSince(started))) s, progress \(await values.all)")
    #expect(!CloudFile.isOnlineOnly(url))
    #expect(await values.all.last == 1)
}
private actor ProgressValues { var all: [Double] = []; func add(_ v: Double) { all.append(v) } }
