import SwiftUI
import Core

struct DirectoryPresentationIndex {
    var courses:[Course]=[]
    var roots:[UUID:[Folder]]=[:]
    var children:[UUID:[Folder]]=[:]
    var pending:[[URL]]=[]
    init(courses:[Course]=[],folders:[Folder]=[],root:String?=nil,pending:[URL]=[]) {
        self.courses=courses.filter{$0.directoryPath?.hasPrefix((root ?? "")+"/")==true}.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}
        for folder in folders.sorted(by:{$0.name.localizedStandardCompare($1.name) == .orderedAscending}) {
            if let parent=folder.parentID {children[parent,default:[]].append(folder)}else{roots[folder.courseID,default:[]].append(folder)}
        }
        self.pending=DirectoryIndex.pendingGroups(pending)
    }
}
@MainActor final class DirectoryPresentation:ObservableObject {
    @Published var course:UUID?
    @Published var folder:UUID?
    @Published private(set) var index=DirectoryPresentationIndex()
    @Published private(set) var missing=Set<UUID>()
    @Published private(set) var unlinkedCount=0
    private var courses:[Course]=[],folders:[Folder]=[],root:String?,pending:[URL]=[]
    private var sources:[UUID:[MediaSource]]=[:]
    private var generation=0
    func update(_ library:Library,pending:[URL]) {
        let count=library.lectures.filter{$0.directoryPath==nil && $0.archived != true}.count
        if count != unlinkedCount {unlinkedCount=count}
        if courses != library.courses || folders != library.folders || root != library.directoryRoot || self.pending != pending {
            courses=library.courses;folders=library.folders;root=library.directoryRoot;self.pending=pending
            index=PerformanceTrace.measure("directory.index"){DirectoryPresentationIndex(courses:courses,folders:folders,root:root,pending:pending)}
        }
        let next=Dictionary(uniqueKeysWithValues:library.lectures.map{($0.id,$0.mediaSources)})
        if sources != next {sources=next;refreshAvailability()}
    }
    func refreshAvailability() {
        generation += 1;let token=generation;let values=sources
        Task {let absent=await Task.detached(priority:.utility) {Set(values.compactMap{id,media in media.contains{!FileManager.default.fileExists(atPath:$0.path)} ? id:nil})}.value
            guard token==generation else{return};if absent != missing {missing=absent}
        }
    }
    func select(course:UUID?,folder:UUID?=nil) {self.course=course;self.folder=folder}
}
extension AppStore {
    func refreshDirectoryPresentation(){navigation.update(library,pending:pendingFiles)}
}
struct DirectorySidebar:View {
    @ObservedObject var navigation:DirectoryPresentation
    @Environment(\.openSettings) private var openSettings
    var body:some View {
        List {
            ForEach(navigation.index.courses) {course in
                Group {
                    if let children=navigation.index.roots[course.id],!children.isEmpty {
                        DisclosureGroup {nodes(children,course:course.id)} label:{courseButton(course)}
                    } else {courseButton(course)}
                }.listRowBackground(navigation.course==course.id && navigation.folder==nil ? Color.accentColor.opacity(0.16):Color.clear)
            }
            if navigation.unlinkedCount>0 {Section {Button("待关联课件 · \(navigation.unlinkedCount)"){navigation.select(course:nil)}}}
        }.listStyle(.sidebar).toolbar(removing:.sidebarToggle).safeAreaInset(edge:.bottom){HStack{Button{openSettings()}label:{Image(systemName:"gearshape")}.buttonStyle(.plain).help("设置（⌘,）").accessibilityLabel("设置");Spacer()}.padding(16)}
    }
    private func courseButton(_ c:Course)->some View {Button{navigation.select(course:c.id)}label:{Label(c.name,systemImage:"folder").lineLimit(1).help(c.name).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())}.buttonStyle(.plain).contextMenu{Button("在 Finder 打开"){if let path=c.directoryPath {NSWorkspace.shared.open(URL(fileURLWithPath:path))}}}}
    private func nodes(_ folders:[Folder],course:UUID)->some View {ForEach(folders){f in DirectoryNode(navigation:navigation,folder:f,course:course)}}
}
private struct DirectoryNode:View {
    @ObservedObject var navigation:DirectoryPresentation
    let folder:Folder;let course:UUID
    var body:some View {
        Group {
            if let children=navigation.index.children[folder.id],!children.isEmpty {DisclosureGroup {ForEach(children){DirectoryNode(navigation:navigation,folder:$0,course:course)}}label:{label}}
            else {label}
        }.listRowBackground(navigation.folder==folder.id ? Color.accentColor.opacity(0.16):Color.clear)
    }
    var label:some View {Button{navigation.select(course:course,folder:folder.id)}label:{Label(folder.name,systemImage:"folder").lineLimit(1).help(folder.name).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())}.buttonStyle(.plain).contextMenu{Button("在 Finder 打开"){if let path=folder.directoryPath {NSWorkspace.shared.open(URL(fileURLWithPath:path))}}}}
}
