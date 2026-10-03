import Foundation

/// Build once per source/grouping change, never for scrolling or appearance updates.
public struct ReadingIndex: Sendable {
    public let units: [TranscriptReadingUnit]
    private let cueUnit: [String:Int]
    public init(_ cues:[Cue] = [],grouped:Bool=true,video:Bool=false) {
        units=ReadingUnits.make(cues,grouped:grouped,video:video)
        var mapping:[String:Int]=[:]
        for (index,unit) in units.enumerated() {for cue in unit.cues {mapping[cue.id]=index}}
        cueUnit=mapping
    }
    public func unitID(for cueID:String)->String? {cueUnit[cueID].map{units[$0].id}}
    public func activeUnits(_ ids:[String])->[TranscriptReadingUnit] {
        Set(ids.compactMap{cueUnit[$0]}).sorted().map{units[$0]}
    }
}
