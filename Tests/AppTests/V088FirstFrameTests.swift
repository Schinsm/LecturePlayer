import AppKit
import AVFoundation
import Foundation
import Testing
import Core
@testable import LecturePlayer

@Suite(.serialized) @MainActor struct V088FirstFrameTests {
    @Test func firstFrameWaitsForAVisibleHostAndOnlyRecoversOnce() {
        let generation = UUID(), binding = UUID()
        var state = VideoFirstFrameState(generation: generation, binding: binding)
        let transition1 = state.observe(generation: generation, binding: binding, eligible: false, hasFrame: false, now: 0)
        #expect(!transition1)
        let transition2 = state.observe(generation: generation, binding: binding, eligible: false, hasFrame: false, now: 100)
        #expect(!transition2)
        #expect(state.status == .idle)
        let transition3 = state.observe(generation: generation, binding: binding, eligible: true, hasFrame: false, now: 100)
        #expect(!transition3)
        #expect(state.status == .waiting)
        let transition4 = state.observe(generation: generation, binding: binding, eligible: true, hasFrame: false, now: 100.5)
        #expect(!transition4)
        #expect(state.status == .loading)
        let transition5 = state.observe(generation: generation, binding: binding, eligible: true, hasFrame: false, now: 104.9)
        #expect(!transition5)
        let transition6 = state.observe(generation: generation, binding: binding, eligible: true, hasFrame: false, now: 105.01)
        #expect(transition6)
        #expect(state.status == .recovering)
        state.recoveryFinished(success: true)
        let transition7 = state.observe(generation: generation, binding: binding, eligible: true, hasFrame: false, now: 110.02)
        #expect(!transition7)
        #expect(state.status == .failed)
        for time in [120.0, 500.0, 10_000.0] {
            let transition8 = state.observe(generation: generation, binding: binding, eligible: true, hasFrame: false, now: time)
            #expect(!transition8)
        }
        #expect(state.automaticRecoveryAttempted)
        let transition9 = state.retry(now: 10_001)
        #expect(transition9)
        let transition10 = state.observe(generation: generation, binding: binding, eligible: true, hasFrame: true, now: 10_002)
        #expect(!transition10)
        #expect(state.status == .ready)
        state.recoveryFinished(success: false)
        #expect(state.status == .ready)
    }
    @Test func staleReadyCallbackAndHiddenTimeCannotSatisfyANewBinding() {
        let generation = UUID(), binding = UUID()
        var state = VideoFirstFrameState(generation: generation, binding: binding)
        let transition11 = state.observe(generation: UUID(), binding: binding, eligible: true, hasFrame: true, now: 0)
        #expect(!transition11)
        let transition12 = state.observe(generation: generation, binding: UUID(), eligible: true, hasFrame: true, now: 0)
        #expect(!transition12)
        #expect(state.status == .idle)
        let transition13 = state.observe(generation: generation, binding: binding, eligible: true, hasFrame: false, now: 1)
        #expect(!transition13)
        let transition14 = state.observe(generation: generation, binding: binding, eligible: false, hasFrame: false, now: 4)
        #expect(!transition14)
        let transition15 = state.observe(generation: generation, binding: binding, eligible: true, hasFrame: false, now: 100)
        #expect(!transition15)
        #expect(state.status == .waiting)
        let transition16 = state.observe(generation: generation, binding: binding, eligible: true, hasFrame: true, now: 100.1)
        #expect(!transition16)
        #expect(state.status == .ready && !state.automaticRecoveryAttempted)
    }
    @Test func pausedItemProducesCurrentFrameWithoutAutoplay() async throws {
        let (_, library, _) = try PersistenceTests().fixture()
        let playback = Playback(); defer { playback.close() }
        playback.load(library.lectures[0]); try await V04PlaybackTests().wait(playback)
        let source = try #require(playback.views.first), item = try #require(playback.player.currentItem)
        let generation = playback.displayGeneration
        var decoded = false
        for _ in 0..<50 {
            decoded = playback.hasCurrentItemFrame(sourceID: source.id, generation: generation, item: item)
            if decoded { break }; try await Task.sleep(for: .milliseconds(20))
        }
        #expect(decoded)
        #expect(!playback.playing && playback.player.rate == 0)
        #expect(abs(playback.position - library.lectures[0].state.position) < 0.05)
        // Old view state is never accepted for a different item or generation.
        let otherItem = AVPlayerItem(url: URL(fileURLWithPath: library.lectures[0].path))
        #expect(!playback.hasCurrentItemFrame(sourceID: source.id, generation: generation, item: otherItem))
        #expect(!playback.hasCurrentItemFrame(sourceID: source.id, generation: UUID(), item: item))
        playback.confirmDisplayedFrame(sourceID: source.id, generation: generation, item: item)
        #expect(!item.outputs.contains { $0 is AVPlayerItemVideoOutput })
        #expect(playback.hasCurrentItemFrame(sourceID: source.id, generation: generation, item: item))
    }
    @Test func recoveryRetainsPausedPositionAndDoesNotWriteCompletionOrProgress() async throws {
        let (_, library, _) = try PersistenceTests().fixture()
        let playback = Playback(); defer { playback.close() }
        playback.load(library.lectures[0]); try await V04PlaybackTests().wait(playback)
        let source = try #require(playback.views.first), item = try #require(playback.player.currentItem)
        let position = playback.position, generation = playback.displayGeneration
        var writes = 0, completionWrites = 0
        playback.save = { _,_,_ in writes += 1 }
        playback.completionChanged = { _,_ in completionWrites += 1 }
        #expect(await playback.recoverFirstFrame(sourceID: source.id, generation: generation, item: item))
        #expect(abs(playback.player.currentTime().seconds - position) < 0.05)
        #expect(!playback.playing && playback.player.rate == 0)
        #expect(writes == 0 && completionWrites == 0)
        // Recreating the view cannot reset the automatic recovery budget.
        #expect(await playback.recoverFirstFrame(sourceID: source.id, generation: generation, item: item) == false)
        #expect(await playback.recoverFirstFrame(sourceID: source.id, generation: generation, item: item, manual: true))
        #expect(writes == 0 && completionWrites == 0)
        playback.save = nil
    }
    @Test func activeFirstFrameRecoveryBlocksFollowerCorrectionAndKeepsPlayingIntent() async throws {
        let (_, library, _) = try PersistenceTests().fixture()
        var lesson = library.lectures[0]; lesson.state.speed = 1
        lesson.sources = [MediaSource(role: .screen, path: lesson.path), MediaSource(role: .camera, path: lesson.path)]
        let playback = Playback(); defer { playback.close() }
        playback.load(lesson); try await V04PlaybackTests().wait(playback); playback.toggle()
        for _ in 0..<100 { if playback.playing { break }; try await Task.sleep(for: .milliseconds(20)) }
        try #require(playback.playing)
        let source = playback.views[1], item = try #require(playback.secondaryPlayer.currentItem), generation = playback.displayGeneration
        var finish: (@Sendable (Bool) -> Void)?, seeks = 0
        playback.seekCommand = { _,_,done in seeks += 1; finish = done }
        let recovery = Task { await playback.recoverFirstFrame(sourceID: source.id, generation: generation, item: item) }
        for _ in 0..<100 { if finish != nil { break }; try await Task.sleep(for: .milliseconds(5)) }
        try #require(finish != nil)
        playback.secondaryPlayer.pause()
        let corrections = playback.correctionCount
        try await Task.sleep(for: .milliseconds(850))
        #expect(seeks == 1 && playback.correctionCount == corrections)
        finish?(true)
        #expect(await recovery.value)
        #expect(playback.playing && playback.secondaryPlayer.rate == 1)
        playback.seekCommand = nil
    }
    @Test func lateRecoveryCannotResumeANewLessonOrOverridePause() async throws {
        let (_, library, _) = try PersistenceTests().fixture()
        let playback = Playback(); defer { playback.close() }
        playback.load(library.lectures[0]); try await V04PlaybackTests().wait(playback)
        let source = try #require(playback.views.first), item = try #require(playback.player.currentItem)
        let generation = playback.displayGeneration
        var finish: (@Sendable (Bool) -> Void)?
        playback.seekCommand = { _,_,done in finish = done }
        let recovering = Task { await playback.recoverFirstFrame(sourceID: source.id, generation: generation, item: item) }
        for _ in 0..<100 { if finish != nil { break }; try await Task.sleep(for: .milliseconds(5)) }
        playback.pause(); finish?(true)
        #expect(await recovering.value == false)
        #expect(!playback.playing && playback.player.rate == 0)
        playback.seekCommand = nil
        var next = library.lectures[0]; next.id = UUID(); next.state.position = 2
        playback.load(next); try await V04PlaybackTests().wait(playback)
        #expect(!playback.matchesDisplayBinding(sourceID: source.id, generation: generation, item: item))
        #expect(await playback.recoverFirstFrame(sourceID: source.id, generation: generation, item: item) == false)
        #expect(playback.lectureID == next.id && abs(playback.position - 2) < 0.05)
    }
}

@MainActor private final class FirstFrameNativeTestDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        print("FIRST_FRAME_NATIVE_TERMINATION_REQUEST cancelled=true")
        return .terminateCancel
    }
}

@Suite(.serialized) @MainActor struct V088FirstFrameNativeAcceptance {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LP088_NATIVE"] == "1"))
    func pausedCanvasDisplaysTwentySuccessiveLoads() async throws {
        let application = NSApplication.shared
        let originalPolicy = application.activationPolicy()
        let originalDelegate = application.delegate
        let hostDelegate = FirstFrameNativeTestDelegate()
        print("FIRST_FRAME_NATIVE_DELEGATE previous=\(String(describing: originalDelegate.map { type(of: $0) }))")
        application.delegate = hostDelegate
        ProcessInfo.processInfo.disableAutomaticTermination("Lecture Player native first-frame acceptance")
        defer {
            application.delegate = originalDelegate
            ProcessInfo.processInfo.enableAutomaticTermination("Lecture Player native first-frame acceptance")
            withExtendedLifetime(hostDelegate) {}
        }
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        // Swift Testing services the async main executor, not NSApplication.run.
        // A native host must also dispatch AppKit events (including occlusion
        // changes) before it can exercise the production visible-view guard.
        func pumpWindowEvents() {
            for _ in 0..<100 {
                guard let event = application.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) else { break }
                application.sendEvent(event)
            }
            application.updateWindows()
        }
        let (_, library, _) = try PersistenceTests().fixture()
        let defaultsName = "LP088.FirstFrame.Native." + UUID().uuidString
        let defaults = UserDefaults(suiteName: defaultsName)!
        let playback = Playback(preferences: defaults)
        let preferences = PictureInPicturePreferences(defaults: defaults)
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 900, height: 620), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = VideoCanvas.Canvas(frame: CGRect(x: 0, y: 0, width: 900, height: 620))
        window.title = "Lecture Player 首帧验收"
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil); application.activate(ignoringOtherApps: true)
        defer { playback.close(); window.close(); defaults.removePersistentDomain(forName: defaultsName); application.setActivationPolicy(originalPolicy) }
        for _ in 0..<100 {
            pumpWindowEvents()
            if window.occlusionState.contains(.visible) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        print("FIRST_FRAME_NATIVE_ACTIVATION active=\(application.isActive) visible=\(window.isVisible) occlusionVisible=\(window.occlusionState.contains(.visible))")
        try #require(window.occlusionState.contains(.visible), "Native test host did not become visible; first-frame visual acceptance cannot run.")
        let iterations = max(1, min(20, Int(ProcessInfo.processInfo.environment["LP088_NATIVE_LOADS"] ?? "20") ?? 20))
        func diagnostic(_ checkpoint: String, load: Int) {
            let timer = Mirror(reflecting: canvas).children.first { $0.label == "frameTimer" }?.value as? Timer
            print("FIRST_FRAME_NATIVE_HOST checkpoint=\(checkpoint) load=\(load) attached=\(canvas.window === window) visible=\(window.isVisible) minimized=\(window.isMiniaturized) occlusionVisible=\(window.occlusionState.contains(.visible)) occlusionRaw=\(window.occlusionState.rawValue) hidden=\(canvas.isHiddenOrHasHiddenAncestor) bounds=\(canvas.bounds) visibleRect=\(canvas.visibleRect) canRecover=\(playback.canRecoverFirstFrame) timerValid=\(timer?.isValid ?? false)")
            for (i, source) in playback.views.enumerated() {
                guard let item = playback.player(for: source).currentItem else { continue }
                let decoded = playback.hasCurrentItemFrame(sourceID: source.id, generation: playback.displayGeneration, item: item)
                print("FIRST_FRAME_NATIVE_SOURCE load=\(load) index=\(i) viewHidden=\(canvas.videos[i].isHidden) bounds=\(canvas.videos[i].bounds) displayReady=\(canvas.videos[i].isReadyForDisplay) decoded=\(decoded) probePresent=\(item.outputs.contains { $0 is AVPlayerItemVideoOutput })")
            }
        }
        for index in 0..<iterations {
            var lesson = library.lectures[0]; lesson.id = UUID(); lesson.state.position = Double(index % 10)
            if index.isMultiple(of: 2) {
                lesson.sources = [MediaSource(role: .screen, path: lesson.path), MediaSource(role: .camera, path: lesson.path)]
            }
            if index.isMultiple(of: 4) {
                var discarded = lesson; discarded.id = UUID(); discarded.state.position = 11
                playback.load(discarded)
                canvas.configure(playback, layout: .inset, swapped: false, preferences: preferences); canvas.layout()
            }
            print("FIRST_FRAME_NATIVE_LOAD index=\(index) phase=begin")
            playback.load(lesson)
            print("FIRST_FRAME_NATIVE_LOAD index=\(index) phase=scheduled")
            try await V04PlaybackTests().wait(playback)
            print("FIRST_FRAME_NATIVE_LOAD index=\(index) phase=media-ready")
            canvas.configure(playback, layout: .inset, swapped: false, preferences: preferences); canvas.layout()
            let items = try playback.views.map { try #require(playback.player(for: $0).currentItem) }
            let began = ProcessInfo.processInfo.systemUptime
            diagnostic("configured", load: index)
            for _ in 0..<100 {
                pumpWindowEvents()
                let ready = items.indices.allSatisfy { canvas.videos[$0].isReadyForDisplay && !items[$0].outputs.contains(where: { $0 is AVPlayerItemVideoOutput }) }
                if ready { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            print("FIRST_FRAME_NATIVE load=\(index) videos=\(items.count) seconds=\(elapsed)")
            diagnostic("checked", load: index)
            for i in items.indices {
                #expect(canvas.videos[i].isReadyForDisplay)
                #expect(!items[i].outputs.contains { $0 is AVPlayerItemVideoOutput })
                #expect(canvas.recoveryButtons[i].isHidden)
            }
            if items.count == 2 {
                canvas.configure(playback, layout: .screen, swapped: false, preferences: preferences); canvas.layout()
                #expect(canvas.videos[1].isHidden)
                canvas.configure(playback, layout: .horizontal, swapped: true, preferences: preferences); canvas.layout()
                try await Task.sleep(for: .milliseconds(50))
                #expect(canvas.videos.allSatisfy { !$0.isHidden && $0.isReadyForDisplay })
            }
            #expect(playback.lectureID == lesson.id)
            #expect(!playback.playing && playback.player.rate == 0 && playback.secondaryPlayer.rate == 0)
            #expect(abs(playback.position - lesson.state.position) < 0.1)
        }
    }
}
