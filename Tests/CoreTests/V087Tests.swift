import Foundation
import Testing
@testable import Core

@Suite struct V087PlaylistTests {
    @Test func courseHierarchyNaturalOrderAndStableTies() {
        var lib=Library();let a=Course(name:"CourseA"),b=Course(name:"IM");lib.courses=[a,b]
        let w10=Folder(name:"Week10",courseID:a.id),w2=Folder(name:"Week2",courseID:a.id)
        let nested=Folder(name:"Lecture",courseID:a.id,parentID:w2.id)
        lib.folders=[w10,nested,w2]
        func lesson(_ title:String,_ folder:UUID?,_ course:UUID)->Lecture {Lecture(title:title,courseID:course,folderID:folder,url:URL(fileURLWithPath:"/sample.mp4"),bookmark:nil,identity:UUID().uuidString)}
        let late=lesson("Lecture 10.1",w10.id,a.id),two=lesson("Lecture 9.2",nested.id,a.id),ten=lesson("Lecture 9.10",nested.id,a.id)
        var tie=lesson("Lecture 9.2",nested.id,a.id),hidden=lesson("Archived",w2.id,a.id)
        tie.id=UUID(uuidString:"00000000-0000-0000-0000-000000000001")!;hidden.archived=true
        let other=lesson("Other",nil,b.id)
        lib.lectures=[late,ten,other,two,tie,hidden]
        let index=CoursePlaylistIndex(lib)
        #expect(index.ids(course:a.id)==[tie.id,two.id,ten.id,late.id])
        #expect(index.sections[a.id]?.map(\.title)==["Week2 / Lecture","Week10"])
        #expect(index.adjacent(to:tie.id,step:-1)==nil)
        #expect(index.adjacent(to:ten.id,step:1)==late.id)
        #expect(index.adjacent(to:late.id,step:1)==nil)
        #expect(index.ids(course:b.id)==[other.id])
        lib.lectures.reverse();#expect(CoursePlaylistIndex(lib)==index)
    }
    @Test func dualMediaIsOneItemAndEmptyCourseIsSafe() {
        var lib=Library();let c=Course(name:"Course");lib.courses=[c]
        var l=Lecture(title:"Dual",courseID:c.id,folderID:nil,url:URL(fileURLWithPath:"/a"),bookmark:nil,identity:"a")
        l.mediaSources=[l.mediaSources[0],MediaSource(role:.camera,path:"/b")];lib.lectures=[l]
        let index=CoursePlaylistIndex(lib)
        #expect(index.ids(course:c.id)==[l.id]);#expect(index.ids(course:UUID()).isEmpty)
        #expect(index.adjacent(to:l.id,step:1)==nil)
    }
}
