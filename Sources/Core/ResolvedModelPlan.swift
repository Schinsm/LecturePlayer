import Foundation

public struct StageModel: Codable, Equatable, Sendable {
    public var model: String
    public var effort: String
    public var pricing: TokenPricing?
    public var reason: String
    public init(_ model: String, _ effort: String, _ reason: String) {
        self.model=model; self.effort=effort; self.reason=reason
        pricing=TranslationModelCatalog.find(model)?.pricing
    }
    public func validate() throws { _ = try TranslationConfig(model:model,effort:effort).descriptor() }
}
public struct ResolvedModelPlan: Codable, Equatable, Sendable {
    public var mode: String
    public var policyVersion = 1
    public var stages: [String:StageModel]
    public static func translation(_ config: TranslationConfig, automatic: Bool) -> Self {
        Self(mode:automatic ? "balanced" : "manual",stages:["translation":StageModel(automatic ? "gpt-5.6-luna" : config.model, automatic ? "none" : config.effort,"逐句翻译，控制延迟与费用")])
    }
    public static func analysis(_ config: AnalysisConfig, automatic: Bool) -> Self {
        Self(mode:automatic ? "balanced" : "manual",stages:[
            "analysis":StageModel(automatic ? "gpt-5.6-luna" : config.model,automatic ? "low" : config.effort,"知识点与原文边界分析"),
            "synthesis":StageModel(automatic ? "gpt-5.6-terra" : config.model,automatic ? "medium" : config.effort,"跨片段主题与整课归纳")])
    }
    public func validate() throws {
        guard policyVersion == 1, ["manual","balanced"].contains(mode), [Set(["translation"]),Set(["analysis","synthesis"])].contains(Set(stages.keys)) else {throw Failure("模型计划版本不受支持")}
        for value in stages.values {try value.validate()}
    }
    public var summary: String {
        ["translation","analysis","synthesis"].compactMap { key in
            stages[key].map {value in let effort=TranslationModelCatalog.find(value.model)?.supportsReasoning == true ? value.effort : "不适用";return "\(value.reason)：\(value.model) · \(effort)" }
        }.joined(separator:"\n")
    }
}
