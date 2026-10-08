import Foundation
import Combine
import Core

@MainActor final class ReaderSession:ObservableObject {
    @Published var panel="transcript"
    @Published var searchRequest=0
    @Published var reader=ReadingState()
    @Published var scrollID:String?
    @Published var overviewExpanded=true
    @Published var expandedTopics=Set<String>()
    @Published var chapterQuery=""
    @Published var chapterDirectoryExpanded=false
    @Published var chapterFollowing=true
    @Published var chapterScrollID:String?
    func browseChapters(){if chapterFollowing {chapterFollowing=false}}
    func followChapters(){chapterQuery="";chapterFollowing=true}
    @Published var openedDocument:Date?
    let content=ReadingContentCache()
}
@MainActor final class ReaderPresentationState {
    private var sessions:[UUID:ReaderSession]=[:]
    private var order:[UUID]=[]
    private var pending:[UUID:String]=[:]
    private var timer:Task<Void,Never>?
    var save:((UUID,String)->Void)?
    func session(_ id:UUID)->ReaderSession {
        if let value=sessions[id] {order.removeAll{$0==id};order.append(id);return value}
        let value=ReaderSession();sessions[id]=value;order.append(id)
        if order.count>6 {let old=order.removeFirst();sessions.removeValue(forKey:old)}
        return value
    }
    func configure(_ id:UUID,panel:String) {flush();if sessions[id]==nil {session(id).panel=panel == "chapters" ? panel:"transcript"}}
    func select(_ panel:String,lesson:UUID) {
        guard session(lesson).panel != panel else{return}
        session(lesson).panel=panel;pending[lesson]=panel
        timer?.cancel();timer=Task {do{try await Task.sleep(for:.milliseconds(350))}catch{return};flush()}
    }
    func flush(){timer?.cancel();timer=nil;let values=pending;pending.removeAll();for(id,panel)in values{save?(id,panel)}}
}
/// Per-session, bounded cache. Changes in a different cue never rebuild this row.
@MainActor final class ReadingContentCache {
    struct Entry {let cues:[Cue];let values:[Core.Translation?];let mode:String;let hidden:Bool;let content:ReadingText}
    private var entries:[String:Entry]=[:]
    private(set) var builds=0
    func content(_ unit:TranscriptReadingUnit,translations:[String:Core.Translation],mode:String,hidden:Bool)->ReadingText {
        let values=unit.cues.map{translations[$0.id]}
        if let old=entries[unit.id],old.cues==unit.cues,old.values==values,old.mode==mode,old.hidden==hidden {return old.content}
        let value=unit.content(translations:translations,mode:mode,hideSpeakers:hidden);builds += 1
        if entries.count>=4096 {entries.removeAll(keepingCapacity:true)}
        entries[unit.id]=Entry(cues:unit.cues,values:values,mode:mode,hidden:hidden,content:value);return value
    }
    func reset(){entries.removeAll(keepingCapacity:false)}
}
