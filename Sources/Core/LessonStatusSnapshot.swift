import Foundation

/// Small presentation values derived from saved content, never from a task's selected scope.
public struct SavedTranslationSummary: Equatable, Sendable {
    public var version: String
    public var total: Int
    public var preferredVariant: String
    public var completedByVariant: [String: Int]
    public init(_ source: Transcript) {
        version=source.version; total=source.cues.count; preferredVariant=source.variantID
        let ids=Set(source.cues.map(\.id))
        if let variants=source.variants {
            completedByVariant=variants.mapValues { variant in
                variant.translations.filter { ids.contains($0.key) && !$0.value.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }.count
            }
        } else {
            completedByVariant=[source.variantID:source.translations.filter { ids.contains($0.key) && !$0.value.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }.count]
        }
    }
    public func completed(variant: String?) -> Int { completedByVariant[variant ?? preferredVariant] ?? 0 }
    public func label(variant: String?) -> String {
        guard total>0 else {return ""}
        let count=completed(variant:variant)
        return count==total ? "翻译完成" : count>0 ? "翻译未完成" : "翻译待处理"
    }
}

public struct SavedAnalysisSummary: Equatable, Sendable {
    public var lessonID: UUID
    public var version: String
    public var complete: Bool
    public var taskStatus: AnalysisTaskStatus?
    public var progress: Double?
    public var message: String?
    public init(_ analysis: LessonAnalysis) {
        lessonID=analysis.lessonID; version=analysis.sourceVersion; complete=analysis.completed != nil
        taskStatus=analysis.task?.status; message=analysis.task?.message
        if let task=analysis.task {
            progress=Double(task.completedChunks.count)/Double(max(1,task.plan.estimatedRequests))
        }
    }
    public var label: String {
        if taskStatus == .failed {return "总结未完成"}
        if taskStatus != nil {return "总结已暂停"}
        return complete ? "总结完成" : "总结待处理"
    }
}
