import Foundation
import Testing
@testable import Core
@testable import LecturePlayer

@Suite(.serialized) @MainActor struct V071AppTests {
    @Test func connectionTestBlocksEveryTranslationEntry() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("LP071-guard-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=AppStore(root:root);let job=store.translation;job.testing=true
        job.launch(store:store,ids:[UUID()],provider:NeverProvider())
        #expect(!job.running && job.authorized.isEmpty)
        #expect(throws:(any Error).self){try job.enqueueImports([],store:store,provider:NeverProvider())}
        job.start(store:store,ids:nil)
        #expect(!job.running)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP071_DATA"] != nil))
    func latestIsolatedDataPreservedOnReopen() throws {
        let path=try #require(ProcessInfo.processInfo.environment["LP071_DATA"])
        #expect(path.hasPrefix("/private/tmp/LP071-"))
        let root=URL(fileURLWithPath:path)
        let files=try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("transcripts"),includingPropertiesForKeys:nil).filter{$0.pathExtension=="json"}
        let before=try files.map{try Data(contentsOf:$0)}
        let first=try Repository(root:root).load(),second=try Repository(root:root).load()
        #expect(first==second)
        var total=0
        for (i,file) in files.enumerated(){let bytes=try Data(contentsOf:file);#expect(bytes==before[i]);let t=try Codec.decode(Transcript.self,bytes);try t.validate();total += t.allTranslatedCount}
        print("LP071 isolated reopen: lessons=\(first.lectures.count), translations=\(total), transcriptBytesUnchanged=true")
    }
}
private struct NeverProvider:TranslationProvider {
    func translate(_ batch:TranslationBatch,config:TranslationConfig) async throws -> TranslationResult {Issue.record("Unexpected translation request");return TranslationResult(items:[])}
}

extension V071AppTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LP071_AZURE_ONE"] == "AUTHORIZED_FIXED_SAMPLE"))
    func authorizedAzureSingleSample() async throws {
        var config=TranslationConfig();config.service = .azure;config.azureRegion="australiaeast"
        let provider=AzureProvider(key:try Keychain.read(.azure),pacer:AzurePacer())
        let result=try await ServiceTest.run(config:config,provider:provider)
        let root=URL(fileURLWithPath:"/private/tmp/LP071-authorized-test")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try await ServiceTestLedger.shared.append(result,root:root)
        print("AZURE_SINGLE_TEST service=Azure region=australiaeast success=\(result.success) seconds=\(result.seconds) text=\(result.translation ?? result.message) meteredCharacters=\(result.usage.meteredCharacters.map(String.init) ?? "unknown")")
        #expect(result.success)
    }
}
