import AppKit
import Core
import Testing
@testable import LecturePlayer

@Suite(.serialized) @MainActor struct V08InteractionTests {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                             styleMask: .borderless, backing: .buffered, defer: false)
        value.isReleasedWhenClosed = false
        return value
    }
    private func key(_ code: UInt16, in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: code))
    }

    @Test func chapterScrollingCannotChangeHiddenTranscriptFollowState() throws {
        let window = window()
        let view = ScrollIntent.IntentView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        var reader = ReadingState()
        view.onManual = {reader.browse()}
        window.contentView?.addSubview(view)
        defer {view.removeFromSuperview(); window.close()}
        #expect(view.monitor != nil)

        view.enabled = false
        #expect(view.monitor == nil)
        // The same event handler is called by the real local monitor, even if an event was already queued.
        #expect(!view.handleScroll(at: NSPoint(x: 100, y: 100), in: window))
        #expect(reader.following)

        view.enabled = true
        #expect(view.monitor != nil)
        #expect(!view.handleScroll(at: NSPoint(x: 400, y: 100), in: window))
        #expect(reader.following)
        #expect(view.handleScroll(at: NSPoint(x: 100, y: 100), in: window))
        #expect(!reader.following)
        reader.search("cash flow")
        view.enabled = false
        #expect(!view.handleScroll(at: NSPoint(x: 100, y: 100), in: window))
        #expect(reader.query == "cash flow" && !reader.following)
    }

    @Test func playerKeysRemainActiveWhenTranscriptKeysAreDisabled() throws {
        let window = window()
        let shared = PlayerKeys.KeysView(frame: .zero), reader = PlayerKeys.KeysView(frame: .zero)
        let cues = [Cue(id: "first", start: 1000, end: 2000, en: "One"),
                    Cue(id: "second", start: 8000, end: 9000, en: "Two")]
        var actions: [PlayerTransportShortcut] = [], readerCalls = 0
        shared.action = {code, modifiers in
            guard let action = PlayerTransportShortcut.resolve(code, modifiers: modifiers, position: 18,
                cues: cues, mapper: SubtitleTimingMapper(offset: 14)) else {return false}
            actions.append(action); return true
        }
        reader.action = {_,_ in readerCalls += 1; return true}
        window.contentView?.addSubview(shared); window.contentView?.addSubview(reader)
        defer {shared.removeFromSuperview(); reader.removeFromSuperview(); window.close()}
        reader.enabled = false
        #expect(reader.monitor == nil && shared.monitor != nil)
        let space = try key(49, in: window)
        #expect(reader.handle(space) === space)
        #expect(shared.handle(space) == nil)
        #expect(shared.handle(try key(123, in: window)) == nil)
        #expect(shared.handle(try key(124, in: window)) == nil)
        #expect(shared.handle(try key(123, in: window, modifiers: .option)) == nil)
        #expect(shared.handle(try key(124, in: window, modifiers: .option)) == nil)
        #expect(actions == [.toggle, .seek(13), .seek(23), .seek(15), .seek(22)])
        #expect(readerCalls == 0)
        // Search remains the visible reader's responsibility; the player must not consume Command-F.
        let search = try key(3, in: window, modifiers: .command)
        #expect(shared.handle(search) === search)
        #expect(actions.count == 5)
    }

    @Test func playerKeysDoNotStealTextInputOrOtherWindowEvents() throws {
        let window = window(), other = self.window()
        let view = PlayerKeys.KeysView(frame: .zero)
        var calls = 0
        view.action = {_,_ in calls += 1; return true}
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(view); window.contentView?.addSubview(editor)
        defer {view.removeFromSuperview(); editor.removeFromSuperview(); window.close(); other.close()}
        #expect(window.makeFirstResponder(editor))
        let typing = try key(49, in: window)
        #expect(view.handle(typing) === typing)
        #expect(calls == 0)
        let elsewhere = try key(49, in: other)
        #expect(view.handle(elsewhere) === elsewhere)
        #expect(calls == 0)
        _ = window.makeFirstResponder(nil)
        view.enabled = false
        #expect(view.monitor == nil)
        #expect(view.handle(typing) === typing)
        #expect(calls == 0)
    }
}
