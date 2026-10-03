import SwiftUI
import Core

private struct ServiceTestProposal:Identifiable {let id=UUID();let config:TranslationConfig}

struct ServiceTestControls:View {
    @ObservedObject private var keyAvailability=KeychainAvailability.shared
    @ObservedObject var store:AppStore
    @ObservedObject var job:TranslationJob
    let config:TranslationConfig
    let unsavedKey:Bool
    let keyRevision:UUID
    @LPState private var result:ServiceTestResult?
    @LPState private var message=""
    @LPState private var stale=false
    @LPState private var proposal:ServiceTestProposal?
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
        HStack {
            Button(job.testing ? "正在测试…" : config.providerID == .apple ? "测试本机翻译…" : "测试连接…"){proposal=ServiceTestProposal(config:config)}
                .disabled(job.busy || unsavedKey || !keyAvailability.configured(config.providerID) || (config.providerID == .azure && (try? AzureRegion.normalize(config.azureRegion ?? "global")) == nil))
            if job.testing {ProgressView().controlSize(.small);Button("取消"){job.serviceTestTask?.cancel()}}
        }
        if unsavedKey {Text("请先保存输入的 Key，再测试连接。").font(.caption)}
        if stale {Text("配置已更改，需重新测试。").font(.caption).foregroundStyle(.secondary)}
        if let result {
            Text(result.message).font(.callout).foregroundStyle(result.success ? Color.green : Color.orange)
            if let text=result.translation {Text(text).textSelection(.enabled)}
            Text("\(result.service.title) · \(result.date.formatted()) · \(String(format:"%.2f",result.seconds)) 秒").font(.caption).foregroundStyle(.secondary)
        }
        if !message.isEmpty {Text(message).font(.caption).foregroundStyle(.red)}
        }.sheet(item:$proposal) { draft in
            let proposed=draft.config
            VStack(alignment:.leading,spacing:16) {
                Text("测试 \(proposed.providerID.title) 翻译").font(.title2)
                Text("测试文本：\n"+ServiceTest.sample).textSelection(.enabled)
                Text(proposed.displayModel)
                if proposed.providerID == .azure {Text("资源区域："+(proposed.azureRegion ?? "global"))}
                Text(proposed.providerID == .apple ? "在本机翻译，首次使用可能需要下载语言资源。" : "本次翻译 \(ServiceTest.sample.utf16.count) 个英文字符，按套餐扣除额度或计费。").font(.callout)
                HStack {Button("取消"){proposal=nil}.keyboardShortcut(.cancelAction);Spacer();Button("开始测试"){proposal=nil;start(proposed)}.keyboardShortcut(.defaultAction).disabled(job.busy)}
            }.padding(24).frame(width:480)
        }.onChange(of:config){_,_ in stale=result != nil || job.testing}.onChange(of:keyRevision){_,_ in stale=result != nil || job.testing}
    }
    private func start(_ frozen:TranslationConfig) {
        guard !job.busy,let root=store.repository?.root else{return}
        do {
            let provider=try job.provider(frozen)
            job.requestGate.setPaused(false);job.testing=true;message="";stale=false
            job.serviceTestTask=Task {@MainActor in
                defer{job.testing=false;job.testRevision += 1;job.serviceTestTask=nil}
                do {
                    let value=try await ServiceTest.run(config:frozen,provider:provider)
                    result=value;stale=stale || config != frozen
                    do{try await ServiceTestLedger.shared.append(value,root:root)}catch{message="测试已结束，但用量记录保存失败："+error.localizedDescription}
                }catch{message="测试未开始："+error.localizedDescription}
            }
        }catch{message=error.localizedDescription}
    }
}
