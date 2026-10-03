import SwiftUI
import Translation
import Core

/// Root-owned session host survives switching lessons and translation display variants.
@available(macOS 15.0, *)
@MainActor final class AppleTranslationEngine:ObservableObject, TranslationProvider {
    @Published var configuration:TranslationSession.Configuration?
    private var pending:CheckedContinuation<TranslationResult,Never>?
    private var batch:TranslationBatch?
    private var generation=UUID()
    func translate(_ batch:TranslationBatch,config:TranslationConfig) async throws -> TranslationResult {
        let batch=batch.withoutSpeakerLabels()
        try Task.checkCancellation()
        guard pending==nil else{throw Failure("本机翻译正在处理上一组")}
        let source=Locale.Language(identifier:"en"),target=Locale.Language(identifier:"zh-Hans")
        let availability=await LanguageAvailability().status(from:source,to:target)
        guard availability != .unsupported else{return TranslationResult(items:[],problem:"此设备不支持英文到简体中文的本机翻译")}
        let token=UUID();generation=token;self.batch=batch
        return await withTaskCancellationHandler {
            await withCheckedContinuation {continuation in
                pending=continuation
                if configuration==nil {configuration=TranslationSession.Configuration(source:source,target:target)}else{configuration?.invalidate()}
            }
        } onCancel: {Task {@MainActor in self.finish(TranslationResult(items:[],problem:"本机翻译已取消，已保存内容保留"),token:token)}}
    }
    func fulfill(_ session:TranslationSession) async {
        let token=generation
        guard let batch,pending != nil else{return}
        do {
            // System-owned consent UI handles language downloads; no automatic cloud fallback.
            try await session.prepareTranslation();try Task.checkCancellation()
            let requests=batch.targets.map{TranslationSession.Request(sourceText:$0.en,clientIdentifier:$0.id)}
            let responses=try await session.translations(from:requests)
            let mapped=responses.map{LocalTranslationResponse(id:$0.clientIdentifier,source:$0.sourceText,text:$0.targetText,targetLanguage:$0.targetLanguage.languageCode?.identifier ?? "")}
            finish(LocalTranslationValidator.result(mapped,targets:batch.targets),token:token)
        } catch {finish(TranslationResult(items:[],problem:"本机翻译未完成：请检查语言资源或稍后重试；没有调用云服务。",diagnostics:TranslationDiagnostics(status:error is CancellationError ? "cancelled" : "failed",model:"apple-system")),token:token)}
    }
    private func finish(_ result:TranslationResult,token:UUID) {
        guard token==generation,let continuation=pending else{return}
        pending=nil;batch=nil;continuation.resume(returning:result)
    }
}
@available(macOS 15.0, *)
struct AppleTranslationHost:View {
    @ObservedObject var engine:AppleTranslationEngine
    var body:some View {Color.clear.frame(width:0,height:0).translationTask(engine.configuration){session in await engine.fulfill(session)}}
}
struct LocalTranslationHost:View {
    let job:TranslationJob
    var body:some View {
        if #available(macOS 15.0,*),let engine=job.localEngine as? AppleTranslationEngine {AppleTranslationHost(engine:engine)}
    }
}
