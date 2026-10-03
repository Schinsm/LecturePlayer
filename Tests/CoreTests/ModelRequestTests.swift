import Foundation
import Testing
@testable import Core

final class ModelMockProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code,data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@Suite(.serialized) struct ModelRequestTests {
    let secret = "MOCK-SECRET-NEVER-EXPORT"
    func provider() -> OpenAIProvider {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [ModelMockProtocol.self]
        return OpenAIProvider(key: secret, session: URLSession(configuration: c))
    }
    func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096)
            while true { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(bytes, count: n) }
        }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func checkModel(_ id: String, effort: String, expectedEffort: String?) async throws {
        let t = try CoreTests().parsed(); let batch = TranslationBatch.make(t)[0]
        ModelMockProtocol.handler = { request in
            let json = try body(request)
            #expect(json["model"] as? String == id)
            let format=(json["text"] as? [String:Any])?["format"] as? [String:Any]
            let schema=format?["schema"] as? [String:Any]
            let properties=schema?["properties"] as? [String:Any]
            let translations=properties?["translations"] as? [String:Any]
            #expect(translations?["type"] as? String == "object")
            #expect(translations?["required"] as? [String] == batch.targets.indices.map { String(format:"c%03d",$0+1) })
            #expect((translations?["properties"] as? [String:Any])?.count == batch.targets.count)
            if let expectedEffort { #expect((json["reasoning"] as? [String:String])?["effort"] == expectedEffort) }
            else { #expect(json["reasoning"] == nil) }
            #expect(!String(describing: json).contains(secret))
            let output = String(data: try JSONSerialization.data(withJSONObject: ["translations": batch.targets.enumerated().map { ["id":String(format:"c%03d",$0.offset+1),"zh":"译文"] }]), encoding: .utf8)!
            return (200, try JSONSerialization.data(withJSONObject: ["status":"completed", "output":[["content":[["type":"output_text","text":output]]]], "usage":["input_tokens":100,"output_tokens":30,"output_tokens_details":["reasoning_tokens":5]]]))
        }
        let result = try await provider().translate(batch, config: TranslationConfig(model: id, effort: effort))
        #expect(result.reasoningTokens == 5)
    }
    @Test func lunaSendsExactIDAndNone() async throws { try await checkModel("gpt-5.6-luna", effort: "none", expectedEffort: "none") }
    @Test func terraSendsSelectedModel() async throws { try await checkModel("gpt-5.6-terra", effort: "low", expectedEffort: "low") }
    @Test func solSendsSelectedModel() async throws { try await checkModel("gpt-5.6-sol", effort: "none", expectedEffort: "none") }
    @Test func miniOmitsEvenPreviouslySavedReasoning() async throws { try await checkModel("gpt-4o-mini", effort: "max", expectedEffort: nil) }
    @Test func unavailableModelIsVisibleWithoutFallbackOrKeyLeak() async throws {
        var calls = 0
        ModelMockProtocol.handler = { request in
            calls += 1; #expect(try body(request)["model"] as? String == "gpt-5.6-luna")
            return (404, try JSONSerialization.data(withJSONObject: ["error":["code":"model_not_found","message":secret]]))
        }
        do { _ = try await provider().translate(TranslationBatch.make(CoreTests().parsed())[0], config: TranslationConfig()); Issue.record("Expected model error") }
        catch {
            #expect(error.localizedDescription.contains("当前 API 账户无法使用 GPT-5.6 Luna"))
            #expect(!error.localizedDescription.contains(secret)); #expect(error.localizedDescription.contains("没有自动切换"))
        }
        #expect(calls == 1)
    }
    @Test func apiKeyAbsentFromBackupAndUsageRecords() throws {
        var t = try CoreTests().parsed(); let config = TranslationConfig()
        t.usage = [TranslationUsage(result: TranslationResult(items: [], inputTokens: 100, outputTokens: 20), config: config, descriptor: try config.descriptor(), batchKey: "batch")]
        let backup = Backup(library: Library(), transcripts: ["test":t])
        let encoded = try Codec.encode(backup); let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains(secret)); #expect(!text.contains("Authorization")); #expect(!text.contains("api-key"))
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            let code = try String(contentsOf: url, encoding: .utf8)
            #expect(!code.contains("print(")); #expect(!code.contains("NSLog("))
        }
    }
}
