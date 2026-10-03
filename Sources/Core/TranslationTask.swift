import Foundation

/// Durable task scope. Translations remain authoritative; task IDs never cause a cached cue to be resent.
public struct TranslationTaskState: Codable, Equatable, Sendable {
    public var variantID:String?
    public var singleCue:Bool?
    public var version: String
    public var ids: [String]
    public var config: TranslationConfig
    public var created = Date()
    public var state = "排队"
    public var failedIDs: [String] = []
    public var retrySize = 5
    public var completed = 0
    public init(transcript:Transcript,ids:[String],config:TranslationConfig) {
        self.variantID=config.providerID.rawValue;self.version=transcript.version;self.ids=ids;self.config=config
    }
    public func batches(_ transcript:Transcript) -> [TranslationBatch] {
        guard transcript.version == version else { return [] }
        let pending=Set(ids.filter { transcript.translations[$0] == nil })
        if config.providerID != .openAI { return config.batches(transcript, ids: pending) }
        if singleCue == true {return TranslationBatch.make(transcript,ids:pending,maxCues:1)}
        let failed=pending.intersection(failedIDs)
        return TranslationBatch.make(transcript,ids:failed,maxCues:retrySize) + TranslationBatch.make(transcript,ids:pending.subtracting(failed))
    }
    public mutating func failed(_ batch:TranslationBatch, transcript:Transcript) {
        let wasRetry = !Set(batch.targets.map(\.id)).isDisjoint(with:failedIDs)
        failedIDs=Array(Set(failedIDs).union(batch.targets.filter { transcript.translations[$0.id] == nil }.map(\.id))).sorted()
        retrySize = wasRetry ? 1 : 5
        state="已暂停"
    }
}
