import SwiftUI
import Core

@MainActor final class PlaylistRowState:ObservableObject,Identifiable {
    let id:UUID
    @Published private(set) var lesson:Lecture
    init(_ lesson:Lecture) {id=lesson.id;self.lesson=lesson}
    func update(_ lesson:Lecture) {if self.lesson != lesson {self.lesson=lesson}}
}
@MainActor final class CoursePlaylistPresentation:ObservableObject {
    @Published private(set) var index=CoursePlaylistIndex(Library())
    private(set) var rows:[UUID:PlaylistRowState]=[:]
    private var topology:[CoursePlaylistIndex.Entry]=[]
    private var folders:[Folder]=[],courses:[Course]=[]
    private(set) var rebuildCount=0
    func update(_ library:Library) {
        let keys=library.lectures.filter{$0.archived != true}.map{CoursePlaylistIndex.Entry(id:$0.id,courseID:$0.courseID,folderID:$0.folderID,title:$0.title)}
        for lesson in library.lectures {updateRow(lesson)}
        rows=rows.filter{id,_ in library.lectures.contains{$0.id==id}}
        if topology != keys || folders != library.folders || courses != library.courses {
            topology=keys;folders=library.folders;courses=library.courses
            index=CoursePlaylistIndex(library);rebuildCount += 1
        }
    }
    func updateRow(_ lesson:Lecture) {
        if let row=rows[lesson.id] {row.update(lesson)}else{rows[lesson.id]=PlaylistRowState(lesson)}
    }
}

struct CoursePlaylistButton:View {
    @ObservedObject var store:AppStore
    @LPState private var showing=false
    var body:some View {
        Button {showing.toggle()}label:{Image(systemName:"list.bullet.rectangle")}
            .help("课程播放列表").accessibilityLabel("课程播放列表")
            .popover(isPresented:$showing,arrowEdge:.top) {
                CoursePlaylistPopover(store:store,presentation:store.playlist,navigation:store.navigation,close:{showing=false})
            }
    }
}
private struct CoursePlaylistPopover:View {
    @ObservedObject var store:AppStore
    @ObservedObject var presentation:CoursePlaylistPresentation
    @ObservedObject var navigation:DirectoryPresentation
    let close:()->Void
    @FocusState private var focus:UUID?
    private var course:UUID? {store.lecture?.courseID}
    private var ids:[UUID] {course.map{presentation.index.ids(course:$0)} ?? []}
    private func choose(_ id:UUID) {
        if store.switchFromPlaylist(to:id) {close()}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                VStack(alignment:.leading,spacing:3) {
                    Text(store.library.courses.first{$0.id==course}?.name ?? "课程播放列表").font(.headline).lineLimit(1)
                    Text("\(ids.count) 集").font(.caption).foregroundStyle(.secondary)
                }
                Spacer();Button(action:close){Image(systemName:"xmark")}.buttonStyle(.plain).accessibilityLabel("关闭播放列表")
            }.padding(14)
            Divider()
            ScrollViewReader {proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:4) {
                        ForEach(course.flatMap{presentation.index.sections[$0]} ?? []) {section in
                            Text(section.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top,10).padding(.horizontal,8)
                            ForEach(section.ids,id:\.self) {id in
                                if let row=presentation.rows[id] {
                                    PlaylistLessonRow(row:row,current:store.current==id,missing:navigation.missing.contains(id),choose:{choose(id)})
                                        .focused($focus,equals:id).id(id)
                                }
                            }
                        }
                    }.padding(8)
                }
                .onAppear {if let id=store.current {proxy.scrollTo(id,anchor:.center);focus=id}}
                .onMoveCommand {direction in
                    let step=direction == .up ? -1:direction == .down ? 1:0
                    guard step != 0,!ids.isEmpty else{return}
                    let position=ids.firstIndex(of:focus ?? store.current ?? ids[0]) ?? 0
                    let id=ids[min(ids.count-1,max(0,position+step))]
                    focus=id;proxy.scrollTo(id,anchor:.center)
                }
            }
            Divider()
            HStack {
                Button("上一集") {if let id=store.current.flatMap({presentation.index.adjacent(to:$0,step:-1)}) {choose(id)}}
                    .disabled(store.current.flatMap{presentation.index.adjacent(to:$0,step:-1)}==nil)
                Spacer()
                Button("下一集") {if let id=store.current.flatMap({presentation.index.adjacent(to:$0,step:1)}) {choose(id)}}
                    .disabled(store.current.flatMap{presentation.index.adjacent(to:$0,step:1)}==nil)
            }.padding(12)
        }.frame(width:360,height:480)
    }
}
private struct PlaylistLessonRow:View {
    @ObservedObject var row:PlaylistRowState
    let current:Bool,missing:Bool
    let choose:()->Void
    var body:some View {
        Button(action:choose) {
            HStack(alignment:.top,spacing:9) {
                Image(systemName:current ? "play.fill":"play.circle").foregroundStyle(current ? Color.accentColor:Color.secondary).frame(width:16)
                VStack(alignment:.leading,spacing:5) {
                    Text(row.lesson.title).lineLimit(2).foregroundStyle(.primary)
                    HStack {
                        if current {Text("当前").foregroundStyle(Color.accentColor)}
                        Text(row.lesson.finished ? "已播完":"\(timeLabel(row.lesson.state.position)) / \(timeLabel(row.lesson.duration))")
                        if missing {Text("媒体缺失").foregroundStyle(.orange)}
                    }.font(.caption).foregroundStyle(.secondary)
                    if row.lesson.duration>0 {ProgressView(value:min(1,max(0,row.lesson.state.position/row.lesson.duration))).controlSize(.mini).accessibilityHidden(true)}
                }
                Spacer(minLength:0)
            }.padding(9).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                .background(current ? Color.accentColor.opacity(0.10):Color.clear,in:RoundedRectangle(cornerRadius:7))
        }.buttonStyle(.plain).help(row.lesson.title).accessibilityLabel(row.lesson.title+(current ? "，当前":"")+(missing ? "，媒体缺失":""))
    }
}
struct PlaylistEndAction:View {
    @ObservedObject var store:AppStore
    @ObservedObject var playback:Playback
    @ObservedObject var presentation:CoursePlaylistPresentation
    var body:some View {
        if playback.naturallyEnded {
            HStack {
                Text("本集已播完").foregroundStyle(.secondary)
                Spacer()
                if let id=store.current.flatMap({presentation.index.adjacent(to:$0,step:1)}) {
                    Button("播放下一集") {_ = store.switchFromPlaylist(to:id)}
                } else {Text("已到课程末尾").foregroundStyle(.secondary)}
            }.font(.caption).padding(.horizontal,4)
        }
    }
}
