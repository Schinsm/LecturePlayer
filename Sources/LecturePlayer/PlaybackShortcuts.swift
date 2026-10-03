import AppKit
import SwiftUI
import Core

enum PlaybackCommand: String, CaseIterable, Codable, Identifiable {
    case toggle, backward, forward, previousCue, nextCue, search
    var id:String {rawValue}
    var title:String {switch self {case .toggle:return "播放／暂停";case .backward:return "后退 5 秒";case .forward:return "前进 5 秒";case .previousCue:return "上一字幕片段";case .nextCue:return "下一字幕片段";case .search:return "搜索转写"}}
    var initial:PlaybackKey {
        switch self {
        case .toggle:return PlaybackKey(code:49,modifiers:[],name:"空格")
        case .backward:return PlaybackKey(code:123,modifiers:[],name:"←")
        case .forward:return PlaybackKey(code:124,modifiers:[],name:"→")
        case .previousCue:return PlaybackKey(code:123,modifiers:.option,name:"←")
        case .nextCue:return PlaybackKey(code:124,modifiers:.option,name:"→")
        case .search:return PlaybackKey(code:3,modifiers:.command,name:"F")
        }
    }
}
struct PlaybackKey:Codable,Equatable {
    let code:UInt16
    let flags:UInt
    let name:String
    static let mask:NSEvent.ModifierFlags=[.command,.control,.option,.shift]
    init(code:UInt16,modifiers:NSEvent.ModifierFlags,name:String) {self.code=code;flags=modifiers.intersection(Self.mask).rawValue;self.name=name}
    init(_ event:NSEvent) {
        let labels:[UInt16:String]=[49:"空格",123:"←",124:"→",125:"↓",126:"↑",36:"Return",48:"Tab",53:"Esc",51:"Delete"]
        self.init(code:event.keyCode,modifiers:event.modifierFlags,name:labels[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "按键 \(event.keyCode)")
    }
    var label:String {let m=NSEvent.ModifierFlags(rawValue:flags);return (m.contains(.control) ? "⌃":"")+(m.contains(.option) ? "⌥":"")+(m.contains(.shift) ? "⇧":"")+(m.contains(.command) ? "⌘":"")+name}
    func matches(_ code:UInt16,_ modifiers:NSEvent.ModifierFlags)->Bool {self.code==code && flags==modifiers.intersection(Self.mask).rawValue}
    var invalidReason:String? {
        // Preserve editing, application and accessibility navigation commands.
        if [36,48,53,51,117].contains(code) {return "Return、Tab、Esc 和删除键保留给系统操作。"}
        let m=NSEvent.ModifierFlags(rawValue:flags)
        if code==49 && (m.contains(.command) || m.contains(.control)) {return "此组合常用于系统搜索或输入法，请换一个组合。"}
        if m.contains(.control) && m.contains(.option) {return "⌃⌥ 组合保留给辅助功能。"}
        if m.contains(.command),[0,6,7,8,9,11,12,13,46,43,47,50].contains(code) {return "此组合保留给应用菜单或文字编辑，请换一个组合。"}
        if flags==0 && ![49,123,124,125,126].contains(code) {return "字母或数字请搭配 ⌘、⌥ 或 ⌃，避免误触。"}
        if flags==NSEvent.ModifierFlags.shift.rawValue && ![123,124,125,126].contains(code) {return "请搭配 ⌘、⌥ 或 ⌃。"}
        return nil
    }
}
@MainActor final class PlaybackShortcuts:ObservableObject {
    static let shared=PlaybackShortcuts()
    @Published private(set) var bindings:[PlaybackCommand:PlaybackKey]=[:]
    private let preferences:UserDefaults
    init(preferences:UserDefaults = .standard) {
        self.preferences=preferences
        bindings=Dictionary(uniqueKeysWithValues:PlaybackCommand.allCases.map{($0,$0.initial)})
        if let data=preferences.data(forKey:"playbackShortcuts.v1"),let saved=try? JSONDecoder().decode([PlaybackCommand:PlaybackKey].self,from:data),saved.count==PlaybackCommand.allCases.count {
            let valid=PlaybackCommand.allCases.allSatisfy {saved[$0]?.invalidReason==nil && saved[$0] != nil}
            let unique=Set(saved.values.map{"\($0.code)-\($0.flags)"}).count==saved.count
            if valid && unique {bindings=saved}
        }
    }
    func key(_ command:PlaybackCommand)->PlaybackKey {bindings[command] ?? command.initial}
    func resolve(_ code:UInt16,_ modifiers:NSEvent.ModifierFlags)->PlaybackCommand? {PlaybackCommand.allCases.first{key($0).matches(code,modifiers)}}
    func set(_ key:PlaybackKey,for command:PlaybackCommand)->String? {
        if let reason=key.invalidReason {return reason}
        if let conflict=PlaybackCommand.allCases.first(where:{$0 != command && self.key($0).matches(key.code,NSEvent.ModifierFlags(rawValue:key.flags))}) {return "已用于“\(conflict.title)”，请使用其他组合。"}
        bindings[command]=key;persist();return nil
    }
    func reset(){bindings=Dictionary(uniqueKeysWithValues:PlaybackCommand.allCases.map{($0,$0.initial)});persist()}
    private func persist(){if let data=try? JSONEncoder().encode(bindings){preferences.set(data,forKey:"playbackShortcuts.v1")}}
    func transport(_ command:PlaybackCommand,position:Double,cues:[Cue],mapper:SubtitleTimingMapper)->PlayerTransportShortcut? {
        switch command {
        case .toggle:return .toggle
        case .backward:return .seek(max(0,position-5))
        case .forward:return .seek(position+5)
        case .previousCue,.nextCue:
            let points=cues.map{mapper.seekTarget($0)}.sorted()
            return (command == .previousCue ? points.last{$0<position-0.3}:points.first{$0>position+0.3}).map{.seek($0)}
        case .search:return nil
        }
    }
}
struct ShortcutSettings:View {
    @ObservedObject private var shortcuts=PlaybackShortcuts.shared
    @LPState private var recording:PlaybackCommand?
    var body:some View {
        Section("快捷键") {
            ForEach(PlaybackCommand.allCases) {command in
                HStack {Text(command.title);Spacer();Button(shortcuts.key(command).label){recording=command}.help("修改"+command.title+"快捷键")}
            }
            Button("恢复默认快捷键"){shortcuts.reset()}
            DisclosureGroup("使用说明") {
                Text("快捷键在应用内生效。编辑文字时使用正常输入；选中文字时方向键调整选区。").font(.caption).foregroundStyle(.secondary)
            }
        }.sheet(item:$recording){command in ShortcutCapture(command:command,shortcuts:shortcuts)}
    }
}
private struct ShortcutCapture:View {
    let command:PlaybackCommand
    @ObservedObject var shortcuts:PlaybackShortcuts
    @Environment(\.dismiss) var dismiss
    @LPState private var error=""
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("设置“\(command.title)”").font(.headline)
            Text("按下新的快捷键组合；Esc 取消。")
            if !error.isEmpty {Text(error).foregroundStyle(.orange)}
            Button("取消"){dismiss()}.keyboardShortcut(.cancelAction)
        }.padding(24).frame(width:380).background(KeyRecorder {event in
            if event.keyCode==53 {dismiss();return}
            if let reason=shortcuts.set(PlaybackKey(event),for:command){error=reason}else{dismiss()}
        })
    }
}
private struct KeyRecorder:NSViewRepresentable {
    let capture:(NSEvent)->Void
    func makeNSView(context:Context)->Recorder {let v=Recorder();v.capture=capture;return v}
    func updateNSView(_ view:Recorder,context:Context){view.capture=capture}
    final class Recorder:NSView {
        var capture:((NSEvent)->Void)?;var monitor:Any?
        override func viewDidMoveToWindow(){super.viewDidMoveToWindow();if let monitor{NSEvent.removeMonitor(monitor);self.monitor=nil};guard window != nil else{return}
            monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown){[weak self] event in
                guard let self,event.window === self.window else{return event}
                if !event.isARepeat {self.capture?(event)};return nil
            }
        }
        deinit{if let monitor{NSEvent.removeMonitor(monitor)}}
    }
}
