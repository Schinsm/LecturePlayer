import Foundation

public enum ReasoningEffort: String, CaseIterable, Codable, Sendable {
    case none, low, medium, high, xhigh, max
    public var displayName: String {
        switch self { case .none: return "None — 推荐用于字幕翻译"; case .low: return "Low"; case .medium: return "Medium"; case .high: return "High"; case .xhigh: return "XHigh"; case .max: return "Max — 更慢且费用可能增加" }
    }
}
public struct TokenPricing: Codable, Equatable, Sendable {
    public let inputPerMillion: Double
    public let outputPerMillion: Double
    public let checkedDate: String
    public let sourceURL: String
    public func estimate(input: Int, output: Int) -> Double {
        (Double(input) * inputPerMillion + Double(output) * outputPerMillion) / 1_000_000
    }
}
public struct TranslationModelDescriptor: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String
    public var supportedEfforts: [ReasoningEffort] = [.none]
    public var supportsStructuredOutput: Bool = true
    public var maximumOutputTokens: Int = 16384
    public let supportsReasoning: Bool
    public let defaultReasoning: ReasoningEffort
    public let pricing: TokenPricing
}
public enum TranslationModelCatalog {
    public static let defaultID = "gpt-5.6-luna"
    public static let models: [TranslationModelDescriptor] = [
        make("gpt-5.6-luna", "GPT-5.6 Luna", "推荐 · 低成本 · Lecture 翻译", [.none,.low,.medium,.high,.xhigh,.max], 128000, 0.20, 1.20),
        make("gpt-4o-mini", "GPT-4o mini", "最低成本 · 快速翻译", [.none], 16384, 0.15, 0.60),
        make("gpt-5.6-terra", "GPT-5.6 Terra", "更高质量 · 成本较高", [.none,.low,.medium,.high,.xhigh,.max], 128000, 2, 12),
        make("gpt-5.6-sol", "GPT-5.6 Sol", "最高质量选项 · 不建议整堂课默认使用", [.none,.low,.medium,.high,.xhigh,.max], 128000, 4, 20)
    ]
    private static func make(_ id: String, _ name: String, _ description: String, _ efforts: [ReasoningEffort], _ outputLimit: Int, _ input: Double, _ output: Double) -> TranslationModelDescriptor {
        TranslationModelDescriptor(id: id, displayName: name, description: description, supportedEfforts: efforts, supportsStructuredOutput: true, maximumOutputTokens: outputLimit, supportsReasoning: efforts.count > 1, defaultReasoning: .none,
            pricing: TokenPricing(inputPerMillion: input, outputPerMillion: output, checkedDate: "2026-09-17", sourceURL: "https://developers.openai.com/api/docs/models/" + id))
    }
    public static func find(_ id: String) -> TranslationModelDescriptor? { models.first { $0.id == id } }
}
public enum TranslationPreferences {
    public static func load(_ defaults: UserDefaults, glossary: String = "", service:TranslationService? = nil) -> TranslationConfig {
        var config = TranslationConfig(model: defaults.string(forKey: "model") ?? TranslationModelCatalog.defaultID,
                          effort: defaults.string(forKey: "effort") ?? ReasoningEffort.none.rawValue, glossary: glossary)
        config.service = service ?? TranslationService(rawValue: defaults.string(forKey:"translationService") ?? "openAI") ?? .openAI
        config.azureRegion = defaults.string(forKey:"azureRegion") ?? "global"
        config.accelerated = defaults.bool(forKey:"translationAccelerated")
        if config.providerID != .openAI {config.model=config.providerID.rawValue+"-standard"}
        if config.providerID == .openAI {
            let plan = ResolvedModelPlan.translation(config, automatic: defaults.bool(forKey:"translationAutomaticModel"))
            if let stage = plan.stages["translation"] { config.model=stage.model; config.effort=stage.effort }
            config.resolvedModels=plan
        }
        return config
    }
}
public extension TranslationConfig {
    var pricingSnapshot: TokenPricing? {
        if let plan=resolvedModels {return plan.stages.values.first(where:{$0.model==model && $0.effort==effort})?.pricing}
        return TranslationModelCatalog.find(model)?.pricing
    }
    func descriptor() throws -> TranslationModelDescriptor {
        guard let model = TranslationModelCatalog.find(model) else { throw Failure("已保存的模型不在支持列表中，请在设置里重新选择；没有自动切换模型。") }
        guard !model.supportsReasoning || model.supportedEfforts.map(\.rawValue).contains(effort) else { throw Failure("推理强度无效，请在设置里重新选择。") }
        return model
    }
}
public struct TranslationCostEstimate: Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let usd: Double?
    public let pricingDate: String?
    public init(batches: [TranslationBatch], config: TranslationConfig, model: TranslationModelDescriptor) {
        // Local heuristic, NOT a tokenizer or a spending cap. Include context, IDs and request overhead.
        inputTokens = batches.reduce(0) { $0 + 700 + ($1.targets + $1.targets + $1.context).reduce(0) { $0 + ($1.en.utf8.count + $1.id.utf8.count + 32 + 2) / 3 } + (config.glossary.utf8.count + 2) / 3 }
        outputTokens = batches.reduce(0) { $0 + 30 + $1.targets.reduce(0) { $0 + ($1.en.utf8.count + 1) / 2 + ($1.en.utf8.count + 2) / 3 + $1.id.utf8.count / 2 + 32 } }
        usd = config.pricingSnapshot?.estimate(input: inputTokens, output: outputTokens)
        pricingDate = config.pricingSnapshot?.checkedDate
    }
    public var summary: String {
        guard let usd,let pricingDate else {return "价格未记录，无法可靠估算费用。输入约 \(inputTokens) / 可见输出约 \(outputTokens) tokens；推理用量不确定。"}
        return "本次批次粗估：输入约 \(inputTokens) / 输出约 \(outputTokens) tokens，约 $\(String(format: "%.4f", usd)) USD。单价日期 \(pricingDate)。这是本应用请求的字符估算，不是账单或上限；未计重试、额外 reasoning、缓存折扣及未来调价。"
    }
}
public struct TranslationUsage: Codable, Equatable, Sendable {
    public var variantID:String?

    public var attemptID: UUID?; public var service: TranslationService?; public var cachedInputTokens: Int?; public var meteredCharacters: Int?; public var submittedCharacters: Int?
    public let date: Date
    public let model: String
    public let effort: String?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let reasoningTokens: Int?
    public let estimatedUSD: Double?
    public let pricing: TokenPricing?
    public let batchKey: String
    public init(result: TranslationResult, config: TranslationConfig, descriptor: TranslationModelDescriptor, batchKey: String) {
        date = Date(); service=config.providerID;cachedInputTokens=result.cachedInputTokens;meteredCharacters=result.meteredCharacters;model = config.providerID == .openAI ? config.model : config.providerID.rawValue+"-standard"; effort = descriptor.supportsReasoning ? config.effort : nil
        inputTokens = result.inputTokens; outputTokens = result.outputTokens; reasoningTokens = result.reasoningTokens
        pricing = config.providerID == .openAI ? config.pricingSnapshot : nil; self.batchKey = batchKey
        if config.providerID == .openAI, let i = result.inputTokens, let o = result.outputTokens { estimatedUSD = pricing?.estimate(input: i, output: o) } else { estimatedUSD = nil }
    }
}
