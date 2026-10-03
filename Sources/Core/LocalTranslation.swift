import Foundation
public struct LocalTranslationResponse:Sendable {
    public let id:String?;public let source:String;public let text:String;public let targetLanguage:String
    public init(id:String?,source:String,text:String,targetLanguage:String){self.id=id;self.source=source;self.text=text;self.targetLanguage=targetLanguage}
}
public enum LocalTranslationValidator {
    public static func result(_ responses:[LocalTranslationResponse],targets:[Cue])->TranslationResult {
        let expected=Dictionary(uniqueKeysWithValues:targets.map{($0.id,$0.en)})
        guard responses.count==targets.count,responses.allSatisfy({$0.id != nil && expected[$0.id!]==$0.source && ["zh","zh-Hans"].contains($0.targetLanguage)}) else{return TranslationResult(items:[],problem:"本机翻译返回的编号、原文或语言不匹配，本组未保存")}
        let items=responses.map{TranslatedItem(id:$0.id!,zh:$0.text)}
        return TranslationResult(items:items,diagnostics:TranslationDiagnostics(status:"completed",model:"apple-system"))
    }
}
