import AppKit
import Testing
import Core
@testable import LecturePlayer

@MainActor @Suite(.serialized) struct V088InteractionTests {
    private func key(_ code:UInt16,_ window:NSWindow,repeatKey:Bool=false)->NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:code==49 ? " " : "",charactersIgnoringModifiers:code==49 ? " " : "",isARepeat:repeatKey,keyCode:code)!
    }
    @Test func focusedHandleRoutesSpaceOnceAndReturnStillActivates() throws {
        _=NSApplication.shared
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:500,height:300),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let handle=ReaderPaneToggle(frame:NSRect(x:0,y:0,width:24,height:56)), keys=PlayerKeys.KeysView()
        window.contentView?.addSubview(handle);window.contentView?.addSubview(keys)
        defer { keys.removeFromSuperview();window.close() }
        var plays=0,toggles=0
        handle.toggle={toggles += 1}
        keys.action={code,_ in guard code==49 else{return false};plays += 1;return true}
        #expect(window.makeFirstResponder(handle))
        #expect(keys.handle(key(49,window))==nil && plays==1 && toggles==0)
        #expect(keys.handle(key(49,window,repeatKey:true))==nil && plays==1)
        let enter=key(36,window)
        #expect(keys.handle(enter) === enter)
        handle.keyDown(with:enter);#expect(toggles==1)
        // A reserved Space can never fall back to activating the hidden handle.
        handle.keyDown(with:key(49,window));#expect(toggles==1)
        #expect(handle.accessibilityPerformPress());#expect(toggles==2)
    }
    @Test func loadingConsumesBoundShortcutButPreservesUnboundKeys() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("LP088-keys-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=AppStore(root:root),page=PlayerPage(store:store)
        #expect(!store.playback.ready)
        let binding=PlaybackShortcuts.shared.key(.toggle)
        #expect(page.playbackKey(binding.code,NSEvent.ModifierFlags(rawValue:binding.flags)))
        #expect(!page.playbackKey(36,[]))
        #expect(!store.playback.playing)
    }
    @Test func openNativeMenuOwnsKeysUntilTrackingEnds() {
        _=NSApplication.shared
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:200,height:100),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let keys=PlayerKeys.KeysView();window.contentView?.addSubview(keys)
        defer {keys.removeFromSuperview();window.close()}
        var plays=0;keys.action={_,_ in plays += 1;return true}
        NotificationCenter.default.post(name:NSMenu.didBeginTrackingNotification,object:NSMenu())
        #expect(keys.handle(key(49,window)) != nil && plays==0)
        NotificationCenter.default.post(name:NSMenu.didEndTrackingNotification,object:NSMenu())
        #expect(keys.handle(key(49,window))==nil && plays==1)
    }
}
