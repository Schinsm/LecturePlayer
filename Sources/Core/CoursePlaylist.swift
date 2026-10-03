import Foundation

/// A course-wide, stable ordering independent of the library's search/filter state.
public struct CoursePlaylistIndex: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let id:UUID
        public let courseID:UUID
        public let folderID:UUID?
        public let title:String
        public init(id:UUID,courseID:UUID,folderID:UUID?,title:String) {self.id=id;self.courseID=courseID;self.folderID=folderID;self.title=title}
    }
    public struct Section: Identifiable, Equatable, Sendable {
        public let id:String
        public let title:String
        public let ids:[UUID]
    }
    public let entries:[Entry]
    public let sections:[UUID:[Section]]
    public init(_ library:Library) {
        let folders=Dictionary(uniqueKeysWithValues:library.folders.map{($0.id,$0)})
        func path(_ id:UUID?)->[(String,UUID)] {
            var result:[(String,UUID)]=[],cursor=id,seen=Set<UUID>()
            while let id=cursor,let f=folders[id],seen.insert(id).inserted {result.insert((f.name,id),at:0);cursor=f.parentID}
            return result
        }
        func compare(_ a:String,_ b:String)->ComparisonResult {a.localizedStandardCompare(b)}
        entries=library.lectures.filter{lesson in lesson.archived != true && library.courses.contains(where:{$0.id==lesson.courseID})}.map{Entry(id:$0.id,courseID:$0.courseID,folderID:$0.folderID,title:$0.title)}.sorted {a,b in
            if a.courseID != b.courseID {return a.courseID.uuidString<b.courseID.uuidString}
            let ap=path(a.folderID),bp=path(b.folderID)
            for (x,y) in zip(ap,bp) {
                let order=compare(x.0,y.0)
                if order != .orderedSame {return order == .orderedAscending}
                if x.1 != y.1 {return x.1.uuidString<y.1.uuidString}
            }
            if ap.count != bp.count {return ap.count<bp.count}
            let title=compare(a.title,b.title)
            return title == .orderedSame ? a.id.uuidString<b.id.uuidString : title == .orderedAscending
        }
        var grouped:[UUID:[Section]]=[:]
        for entry in entries {
            let key=entry.folderID?.uuidString ?? "root",title=path(entry.folderID).map(\.0).joined(separator:" / ")
            var list=grouped[entry.courseID] ?? []
            if let last=list.last,last.id==key {list[list.count-1]=Section(id:key,title:last.title,ids:last.ids+[entry.id])}
            else {list.append(Section(id:key,title:title.isEmpty ? "课程目录":title,ids:[entry.id]))}
            grouped[entry.courseID]=list
        }
        sections=grouped
    }
    public func ids(course:UUID)->[UUID] {sections[course,default:[]].flatMap(\.ids)}
    public func adjacent(to id:UUID,step:Int)->UUID? {
        guard let entry=entries.first(where:{$0.id==id}) else{return nil}
        let list=ids(course:entry.courseID)
        guard let i=list.firstIndex(of:id),list.indices.contains(i+step) else{return nil}
        return list[i+step]
    }
}
