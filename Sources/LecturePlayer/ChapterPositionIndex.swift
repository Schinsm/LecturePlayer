import Foundation
import Core

struct ChapterPositionIndex {
    struct Entry {let id:String;let start:Double;let end:Double}
    /// A reading location persists through silence; the active subtitle still uses cue ends.
    static func readingAnchor(_ entries:[Entry],seconds:Double)->String? {
        guard seconds.isFinite else{return nil}
        var low=0,high=entries.count
        while low<high {let middle=(low+high)/2;if entries[middle].start<=seconds{low=middle+1}else{high=middle}}
        return low>0 ? entries[low-1].id:nil
    }
    static func current(_ entries:[Entry],seconds:Double)->String? {
        var low=0,high=entries.count
        while low<high {let middle=(low+high)/2;if entries[middle].start<=seconds{low=middle+1}else{high=middle}}
        guard low>0,seconds<entries[low-1].end else{return nil};return entries[low-1].id
    }
}

enum ChapterActivity {
    static func parents(_ topics:[AnalysisTopic])->[String:String] {
        Dictionary(topics.flatMap {topic in topic.subtopics.map{($0.id,topic.id)}},uniquingKeysWith:{first,_ in first})
    }
}
