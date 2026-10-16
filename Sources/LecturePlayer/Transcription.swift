import Foundation
import AVFoundation
import AppKit
import Speech
import Core

/// Turns a lesson's audio into timed English text, on this Mac.
protocol TranscriptionEngine: Sendable {
    func transcribe(_ media: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedText]
}

enum TranscriptionSupport {
    /// The on-device engine needs macOS 26 (SpeechAnalyzer). Earlier systems can still use MacWhisper.
    static var onDevice: Bool { if #available(macOS 26, *) { true } else { false } }
    static var engine: (any TranscriptionEngine)? { if #available(macOS 26, *) { AppleSpeechEngine() } else { nil } }
    static let localeKey = "transcriptionLocale"
    static var locale: Locale { Locale(identifier: UserDefaults.standard.string(forKey: localeKey) ?? "en-AU") }
    static var macWhisper: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.goodsnooze.MacWhisper") }
}

@available(macOS 26, *)
struct AppleSpeechEngine: TranscriptionEngine {
    func transcribe(_ media: URL, locale wanted: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedText] {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else { throw Failure("本机转写不支持所选语言") }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            progress(0); try await request.downloadAndInstall()
        }
        // Only the audio track is read; the result goes to a temporary file that is removed afterwards.
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("lp-transcribe-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audio) }
        let asset = AVURLAsset(url: media)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw Failure("无法读取视频音轨") }
        try await export.export(to: audio, as: .m4a)
        let file = try AVAudioFile(forReading: audio)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task { () -> [TimedText] in
            var segments: [TimedText] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                segments.append(TimedText(start: result.range.start.seconds, end: result.range.end.seconds, text: text))
                if duration > 0 { progress(min(1, result.range.end.seconds / duration)) }
            }
            return segments
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: last) }
            else { await analyzer.cancelAndFinishNow() }
        } catch { collect.cancel(); throw error }
        return try await collect.value
    }
}

/// One lesson at a time, so a long lecture does not compete with itself for the Neural Engine.
@MainActor final class TranscriptionJob: ObservableObject {
    struct Item: Equatable { var id: UUID; var thenProcess: Bool }
    @Published private(set) var queue: [Item] = []
    @Published private(set) var current: UUID?
    @Published private(set) var progress = 0.0
    @Published private(set) var failures: [UUID: String] = [:]
    /// True while the current lesson's video is still being fetched from a cloud folder.
    @Published private(set) var downloading = false
    private var worker: Task<Void, Never>?
    var engine: (any TranscriptionEngine)? = TranscriptionSupport.engine

    var available: Bool { engine != nil }
    func isQueued(_ id: UUID) -> Bool { current == id || queue.contains { $0.id == id } }

    /// `thenProcess`: after the subtitles exist, queue translation and chapters as chosen in Settings.
    func enqueue(_ ids: [UUID], store: AppStore, thenProcess: Bool = false) {
        guard available else { return }
        for id in ids where !isQueued(id) { queue.append(Item(id: id, thenProcess: thenProcess)); failures[id] = nil }
        guard worker == nil else { return }
        worker = Task { [weak self, weak store] in
            while let self, let store, !Task.isCancelled, !self.queue.isEmpty {
                let item = self.queue.removeFirst()
                await self.run(item, store: store)
            }
            self?.current = nil; self?.worker = nil
        }
    }
    func cancel(_ id: UUID) {
        queue.removeAll { $0.id == id }
        if current == id { worker?.cancel(); worker = nil; current = nil }
    }

    private func run(_ item: Item, store: AppStore) async {
        guard let engine, let lesson = store.library.lectures.first(where: { $0.id == item.id }), lesson.transcriptVersion == nil,
              let source = ThumbnailRequest.source(for: lesson) else { failures[item.id] = "找不到视频文件"; return }
        current = item.id; progress = 0
        let started = Date()
        do {
            let file = URL(fileURLWithPath: source.path)
            if CloudFile.isOnlineOnly(file) {
                downloading = true; defer { downloading = false }
                try await CloudFile.download(file) { value in
                    Task { @MainActor [weak self] in if self?.current == item.id { self?.progress = value } }
                }
                progress = 0
            }
            let segments = try await engine.transcribe(URL(fileURLWithPath: source.path), locale: TranscriptionSupport.locale) { value in
                Task { @MainActor [weak self] in if self?.current == item.id { self?.progress = value } }
            }
            try Task.checkCancellation()
            guard !segments.isEmpty else { throw Failure("没有识别出语音") }
            PerformanceTrace.record("transcription.seconds", Date().timeIntervalSince(started))
            try store.attachTranscription(item.id, vtt: TranscriptionOutput.vtt(segments), source: .appleSpeech)
            if item.thenProcess { store.processTranscribed(item.id) }
        } catch is CancellationError {
        } catch { failures[item.id] = error.localizedDescription }
        if current == item.id { current = nil }
    }
}

extension AppStore {
    /// Saves machine subtitles beside the course's exports and makes them the lesson's English subtitles.
    /// Only for lessons without subtitles: an existing transcript is never replaced this way.
    func attachTranscription(_ id: UUID, vtt: String, source: TranscriptSource) throws {
        guard let lesson = library.lectures.first(where: { $0.id == id }) else { throw Failure("课件已不存在") }
        guard lesson.transcriptVersion == nil else { throw Failure("课件已有字幕，未覆盖") }
        let data = Data(vtt.utf8)
        let transcript = try SubtitleParser.parse(data, format: "vtt")
        guard !transcript.cues.isEmpty else { throw Failure("转写结果为空") }
        let url = try TranscriptionOutput.url(for: lesson)
        try data.write(to: url, options: .atomic)
        try repository?.write(transcript, for: id)
        updateLecture(id) { $0.transcriptVersion = transcript.version; $0.subtitlePath = url.path; $0.transcriptSource = source }
        if current == id { self.transcript = transcript }
    }

    /// Queues translation and chapters for a freshly transcribed lesson, following the import settings.
    func processTranscribed(_ id: UUID) {
        guard let lesson = library.lectures.first(where: { $0.id == id }), let t = try? repository?.read(lesson) else { return }
        let defaults = UserDefaults.standard
        let translate = defaults.object(forKey: ImportStepPlan.translateKey) as? Bool ?? true
        let chapters = defaults.object(forKey: ImportStepPlan.chaptersKey) as? Bool ?? true
        let config = TranslationPreferences.load(.standard, glossary: library.courses.first { $0.id == lesson.courseID }?.glossary ?? "")
        let task = translate ? TranslationTaskState(transcript: t, ids: t.cues.map(\.id), config: config) : nil
        let analysis = chapters ? (try? AnalysisPlan.make(t)).map { AnalysisTaskState(config: AnalysisPreferences.load(), plan: $0) } : nil
        guard task != nil || analysis != nil else { return }
        do { try processing.launch([ImportProcessingEntry(id: id, translation: task, analysis: analysis)], store: self, deferIfPaused: true) }
        catch { self.error = "转写已完成，但未能加入处理队列：" + error.localizedDescription }
    }

    /// Opens the lesson's video in MacWhisper. Exporting VTT next to the video lets the next refresh pick it up.
    func openInMacWhisper(_ id: UUID) {
        guard let app = TranscriptionSupport.macWhisper, let lesson = library.lectures.first(where: { $0.id == id }),
              let source = ThumbnailRequest.source(for: lesson) else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: source.path)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Links a subtitle that appeared next to a video that had none, e.g. a VTT exported from MacWhisper.
    func adoptNewSubtitles() {
        for lesson in library.lectures where lesson.transcriptVersion == nil && lesson.archived != true && !transcription.isQueued(lesson.id) {
            guard let source = ThumbnailRequest.source(for: lesson) else { continue }
            let video = URL(fileURLWithPath: source.path)
            let files = (try? FileManager.default.contentsOfDirectory(at: video.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
            let candidates = ImportPlanner.candidates(for: video, in: files)
            guard candidates.count == 1 else { continue }
            // Reading a cloud placeholder would block; ask for it now and link it on a later refresh.
            if CloudFile.isOnlineOnly(candidates[0]) { CloudFile.requestDownload(candidates[0]); continue }
            guard let data = try? Data(contentsOf: candidates[0]),
                  let t = try? SubtitleParser.parse(data, format: candidates[0].pathExtension), !t.cues.isEmpty else { continue }
            do {
                try repository?.write(t, for: lesson.id)
                updateLecture(lesson.id) { $0.transcriptVersion = t.version; $0.subtitlePath = candidates[0].path }
            } catch { storageFailed(error) }
        }
    }
}

import SwiftUI

/// Transcription state and actions for one lesson without subtitles.
struct TranscribeControl: View {
    let store: AppStore
    let lessonID: UUID
    var compact = false
    @ObservedObject private var job: TranscriptionJob
    init(store: AppStore, lessonID: UUID, compact: Bool = false) {
        self.store = store; self.lessonID = lessonID; self.compact = compact; job = store.transcription
    }
    var body: some View {
        if job.current == lessonID {
            HStack(spacing: 8) {
                ProgressView(value: job.progress).frame(width: compact ? 60 : 140)
                Text("\(job.downloading ? "下载" : "转写") \(Int(job.progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                if !compact { Button("取消") { job.cancel(lessonID) }.buttonStyle(.borderless) }
            }.font(.caption)
        } else if job.isQueued(lessonID) {
            Label("排队转写", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 10) {
                if job.available {
                    Button { job.enqueue([lessonID], store: store) } label: { Label("转写", systemImage: "waveform") }
                        .help("在本机把视频语音转成英文字幕，不收费")
                }
                if !compact, TranscriptionSupport.macWhisper != nil {
                    Button("用 MacWhisper 打开…") { store.openInMacWhisper(lessonID) }
                        .help("在 MacWhisper 中转写，把 VTT 导出到视频旁边，刷新课程目录后自动关联")
                }
                if let failure = job.failures[lessonID] { Text(failure).foregroundStyle(.orange).lineLimit(1).help(failure) }
            }.font(.caption).buttonStyle(.borderless)
        }
    }
}
