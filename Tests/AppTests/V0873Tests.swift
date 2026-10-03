import AppKit
import AVFoundation
import Testing
@testable import Core
@testable import LecturePlayer

@MainActor @Suite(.serialized) struct V0873Tests {
    func defaults() -> (UserDefaults, String) {
        let name = "LP0873-test-" + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }
    @Test func geometryPreservesAspectAndBoundsAtEveryEdge() throws {
        for aspect in [16.0 / 9, 4.0 / 3, 9.0 / 16] {
            for bounds in [CGRect(x: 0, y: 0, width: 820, height: 820), CGRect(x: 0, y: 0, width: 1920, height: 400), CGRect(x: 10, y: 15, width: 420, height: 700)] {
                for x in [0.0, 0.43, 1.0] {
                    for y in [0.0, 0.37, 1.0] {
                        let placement = PictureInPicturePlacement(x: x, y: y, width: 0.32)
                        let frame = try #require(PictureInPictureGeometry.frame(bounds: bounds, aspect: aspect, placement: placement))
                        #expect(abs(frame.width / frame.height - aspect) < 0.00001)
                        #expect(bounds.insetBy(dx: 11.99, dy: 11.99).contains(frame))
                        let roundTrip = PictureInPictureGeometry.moving(origin: frame.origin, bounds: bounds, aspect: aspect, placement: placement)
                        #expect(abs(roundTrip.x - x) < 0.00001 && abs(roundTrip.y - y) < 0.00001)
                    }
                }
            }
        }
        #expect(PictureInPictureGeometry.frame(bounds: .zero, aspect: 1, placement: .init()) == nil)
        #expect(PictureInPictureGeometry.aspect(CGSize(width: 0, height: 1)) == nil)
        #expect(PictureInPictureGeometry.aspect(CGSize(width: Double.infinity, height: 1)) == nil)
    }
    @Test func insetWaitsForDimensionsAndSwapUsesCorrectSource() throws {
        let screen = MediaSource(role: .screen, path: "screen"), camera = MediaSource(role: .camera, path: "camera")
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 800)
        #expect(videoFrames([screen,camera], mode: .inset, swapped: false, bounds: bounds)[1] == nil)
        let sizes = [screen.id: CGSize(width: 1200, height: 1600), camera.id: CGSize(width: 1920, height: 1080)]
        let normal = videoFrames([screen,camera], mode: .inset, swapped: false, bounds: bounds, sizes: sizes)
        #expect(normal[0] == bounds)
        #expect(abs(normal[1]!.height - 144) < 0.001)
        let swapped = videoFrames([screen,camera], mode: .inset, swapped: true, bounds: bounds, sizes: sizes)
        #expect(swapped[1] == bounds && abs(swapped[0]!.height - 256 / 0.75) < 0.001)
        #expect(videoFrames([screen], mode: .inset, swapped: false, bounds: bounds)[0] == bounds)
    }
    @Test func dragPreviewWritesOnlyOnceAndMemorySurvivesReopen() throws {
        let (d,name) = defaults(); defer { d.removePersistentDomain(forName: name) }
        let prefs = PictureInPicturePreferences(defaults: d)
        for i in 0..<100 { prefs.preview(.init(x: Double(i) / 100, y: 0.4, width: 0.42)) }
        #expect(prefs.writeCount == 0 && d.data(forKey: PictureInPicturePreferences.key) == nil)
        prefs.flush(); prefs.flush()
        #expect(prefs.writeCount == 1)
        #expect(PictureInPicturePreferences(defaults: d).value == prefs.value)
        prefs.reset(); #expect(prefs.value == .init() && prefs.writeCount == 2)
        prefs.preview(.init(x: -3, y: 9, width: 8)); prefs.flush()
        #expect(prefs.value == .init(x: 0, y: 1, width: 0.5))
    }
    @Test func keyboardEditsCoalesceAndInvalidPreferencesUseDefaults() async throws {
        let (d,name) = defaults(); defer { d.removePersistentDomain(forName: name) }
        d.set(Data("invalid".utf8), forKey: PictureInPicturePreferences.key)
        let prefs = PictureInPicturePreferences(defaults: d)
        #expect(prefs.value == .init())
        for i in 0..<20 { prefs.preview(.init(x: Double(i)/20, y: 0.5, width: 0.3)); prefs.saveSoon() }
        #expect(prefs.writeCount == 0)
        for _ in 0..<100 { if prefs.writeCount > 0 { break }; try await Task.sleep(for: .milliseconds(20)) }
        #expect(prefs.writeCount == 1)
    }
    @Test func canvasDragResizeRetainsPlayersAndPauseState() async throws {
        _ = NSApplication.shared
        let (_,lib,_) = try PersistenceTests().fixture()
        var lesson = lib.lectures[0]
        let screen = MediaSource(role: .screen, path: lesson.path)
        let camera = MediaSource(role: .camera, path: lesson.path)
        lesson.sources = [screen,camera]
        let playback = Playback(); defer { playback.close() }
        playback.load(lesson)
        try await V087AppTests().wait(playback)
        for _ in 0..<100 { if playback.displaySizes.count == 2 { break }; try await Task.sleep(for: .milliseconds(20)) }
        #expect(playback.displaySizes.count == 2)
        let (d,name) = defaults(); defer { d.removePersistentDomain(forName: name) }
        let prefs = PictureInPicturePreferences(defaults: d)
        let canvas = VideoCanvas.Canvas(frame: CGRect(x: 0,y: 0,width: 900,height: 700))
        canvas.configure(playback, layout: .inset, swapped: false, preferences: prefs); canvas.layout()
        let first = canvas.videos[0].player, second = canvas.videos[1].player
        let position = playback.position
        canvas.moveInset(dx: -5000, dy: -5000, keyboard: false)
        #expect(abs(canvas.handle.frame.minX - 12) < 0.01 && abs(canvas.handle.frame.minY - 12) < 0.01)
        for _ in 0..<100 { canvas.resizeInset(dx: 2, keyboard: false) }
        #expect(prefs.writeCount == 0 && prefs.value.width <= 0.5)
        canvas.handle.commit?(); #expect(prefs.writeCount == 1)
        canvas.frame.size = CGSize(width: 460, height: 300); canvas.layout()
        #expect(canvas.bounds.contains(canvas.handle.frame))
        #expect(canvas.videos[0].player === first && canvas.videos[1].player === second)
        #expect(playback.position == position && !playback.playing)
        canvas.configure(playback, layout: .inset, swapped: true, preferences: prefs); canvas.layout()
        #expect(canvas.videos[0].player === first && canvas.videos[1].player === second)
        playback.close(); canvas.configure(playback, layout: .inset, swapped: false, preferences: prefs); canvas.layout()
        #expect(canvas.handle.isHidden)
    }
    func key(_ code: UInt16, _ text: String, window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
    @Test func speedKeyboardSelectionDismissAndPiPKeysDoNotSeek() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0,y: 0,width: 400,height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let content = SpeedOptionsView(); content.build(); window.contentView?.addSubview(content)
        var chosen: Int?, dismissed = false
        content.choose = { chosen = $0 }; content.dismiss = { dismissed = true }
        content.keyDown(with: key(125, "", window: window)); content.keyDown(with: key(49, " ", window: window))
        #expect(chosen == 2)
        content.keyDown(with: key(53, "", window: window)); #expect(dismissed)
        let handle = PictureInPictureHandle(frame: CGRect(x: 0,y: 0,width: 100,height: 100))
        window.contentView?.addSubview(handle); window.makeFirstResponder(handle)
        let keys = PlayerKeys.KeysView(); window.contentView?.addSubview(keys)
        var transport = 0; keys.action = { _,_ in transport += 1; return true }
        #expect(keys.handle(key(123, "", window: window)) != nil && transport == 0)
        #expect(handle.accessibilityCustomActions()?.count == 6)
    }
    @Test func latestOnlyMediaDimensionsAfterRapidSwitch() async throws {
        let (_,lib,_) = try PersistenceTests().fixture()
        var first = lib.lectures[0], second = lib.lectures[0]
        first.sources = [MediaSource(role: .screen, path: first.path)]
        second.id = UUID(); second.sources = [MediaSource(role: .screen, path: second.path)]
        let playback = Playback(); defer { playback.close() }
        playback.load(first); playback.load(second)
        try await V087AppTests().wait(playback)
        for _ in 0..<100 { if !playback.displaySizes.isEmpty { break }; try await Task.sleep(for: .milliseconds(20)) }
        #expect(Set(playback.displaySizes.keys) == Set(second.mediaSources.map(\.id)))
    }
}

@MainActor @Suite(.serialized) struct V0873Acceptance {
    @Test func rotatedAssetUsesPresentationAspect() async throws {
        let (_,library,_) = try PersistenceTests().fixture()
        let asset = AVURLAsset(url: URL(fileURLWithPath: library.lectures[0].path))
        let source = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let composition = AVMutableComposition()
        let track = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)), of: source, at: .zero)
        let natural = try await source.load(.naturalSize)
        track.preferredTransform = CGAffineTransform(a: 0,b: 1,c: -1,d: 0,tx: natural.height,ty: 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rotated-" + UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let exporter = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        exporter.outputURL = url; exporter.outputFileType = .mov
        await exporter.export()
        #expect(exporter.status == .completed)
        var lesson = library.lectures[0]; lesson.sources = [MediaSource(role: .screen, path: url.path)]; lesson.state.position = 0
        let player = Playback(); defer { player.close() }
        player.load(lesson); try await V087AppTests().wait(player)
        for _ in 0..<100 { if !player.displaySizes.isEmpty { break }; try await Task.sleep(for: .milliseconds(20)) }
        let size = try #require(player.displaySizes[lesson.mediaSources[0].id])
        #expect(abs(size.width / size.height - natural.height / natural.width) < 0.01)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LP0873_ACCEPTANCE"] == "1"))
    func latestLibraryAndAllContentSurvivePreferenceChanges() throws {
        let base = URL(fileURLWithPath: "/private/tmp/LP0873/baseline-data")
        let root = URL(fileURLWithPath: "/private/tmp/LP0873/regression-" + UUID().uuidString)
        try FileManager.default.copyItem(at: base, to: root)
        let repo = try Repository(root: root), before = try repo.load()
        let transcripts = try before.lectures.compactMap { try repo.read($0) }
        let analyses = try AnalysisRepository.readAll(root: root)
        let (d,name) = V0873Tests().defaults(); defer { d.removePersistentDomain(forName: name) }
        let prefs = PictureInPicturePreferences(defaults: d)
        for i in 0..<200 { prefs.preview(.init(x: Double(i % 100)/100,y: 0.3,width: 0.4)) }
        prefs.flush()
        try repo.save(before)
        #expect(try Repository(root: root).load() == before)
        #expect(try before.lectures.compactMap { try repo.read($0) } == transcripts)
        #expect(try AnalysisRepository.readAll(root: root) == analyses)
        let result: [String: Int] = ["lessons": before.lectures.count, "cues": transcripts.reduce(0) { $0 + $1.cues.count }, "translations": transcripts.reduce(0) { $0 + $1.allTranslatedCount }, "analyses": analyses.count, "preferenceWrites": prefs.writeCount]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: "/private/tmp/LP0873/preservation.json"))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LP0873_NATIVE"] == "1"))
    func nativePopoverStaysBesideButtonAndClosesOnResize() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 100,y: 100,width: 720,height: 450), styleMask: [.titled,.resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = SpeedAnchorButton(frame: CGRect(x: 500,y: 20,width: 60,height: 24))
        window.contentView?.addSubview(button); window.orderFront(nil)
        defer { button.closePanel(); window.close() }
        button.showPanel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(button.panel?.isShown == true)
        let popup = try #require(button.panel?.contentViewController?.view.window)
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        #expect(popup.frame.minY >= anchor.minY)
        #expect(abs(popup.frame.midX - anchor.midX) < 100)
        #expect(popup.frame.minY - anchor.maxY < 30)
        let keys = PlayerKeys.KeysView(); window.contentView?.addSubview(keys)
        var calls = 0; keys.action = { _,_ in calls += 1; return true }
        #expect(keys.handle(V0873Tests().key(49," ",window: window)) != nil && calls == 0)
        button.setFrameOrigin(CGPoint(x: 420, y: 20))
        #expect(SpeedAnchorButton.active == nil && button.panel == nil)
        button.showPanel(); window.setContentSize(CGSize(width: 740,height: 450))
        #expect(SpeedAnchorButton.active == nil)
    }
}
