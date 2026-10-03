import Foundation
public struct ImportProcessingEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var translation: TranslationTaskState?
    public var analysis: AnalysisTaskState?
    public var purpose: String?
    public var regenerateAnalysis:Bool?
    public var analysisReconfirmed:Bool?
    public var created = Date()
    public var status = "等待处理"
    public init(id:UUID,translation:TranslationTaskState?,analysis:AnalysisTaskState?) {self.id=id;self.translation=translation;self.analysis=analysis}
    public static func read(root:URL) throws -> [Self]? {
        let file=root.appendingPathComponent("processing-queue.json")
        guard FileManager.default.fileExists(atPath:file.path) else{return nil}
        return try Codec.decode([Self].self,Data(contentsOf:file))
    }
}
