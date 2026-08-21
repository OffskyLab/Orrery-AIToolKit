import Foundation
import Testing
@testable import AIToolKit

@Suite("PluginServer")
struct PluginServerTests {

    private struct Sample: AITool {
        let id = "sample"
        let displayName = "Sample"
    }

    private func reply(to method: String) throws -> JSONRPCResponse? {
        let req = JSONRPCRequest(id: 1, method: method, params: nil)
        let line = try JSONEncoder().encode(req)
        guard let out = PluginServer.handle(line: line, tool: Sample()) else { return nil }
        return try JSONDecoder().decode(JSONRPCResponse.self, from: out)
    }

    @Test("initialize reports the protocol version and its capabilities")
    func initializeAnswers() throws {
        let res = try #require(try reply(to: "initialize"))
        guard case .object(let obj) = try #require(res.result) else {
            Issue.record("expected an object result"); return
        }
        #expect(obj["protocolVersion"] == .string(PluginServer.protocolVersion))
        guard case .object(let caps) = try #require(obj["capabilities"]) else {
            Issue.record("expected capabilities to be an object"); return
        }
        #expect(caps["tool/describe"] == .bool(true))
    }

    @Test("tool/describe answers with the tool's own fields")
    func describeAnswers() throws {
        let res = try #require(try reply(to: "tool/describe"))
        guard case .object(let obj) = try #require(res.result) else {
            Issue.record("expected an object result"); return
        }
        #expect(obj["id"] == .string("sample"))
        #expect(obj["displayName"] == .string("Sample"))
        #expect(obj["configDirectoryName"] == .string(".sample"))
    }

    @Test("an unimplemented method answers -32601 rather than going silent")
    func unknownMethodIsMethodNotFound() throws {
        let res = try #require(try reply(to: "tool/nope"))
        #expect(res.error?.code == -32601)
    }

    @Test("an unparseable line produces no reply and does not throw")
    func garbageLineIsIgnored() {
        #expect(PluginServer.handle(line: Data("not json".utf8), tool: Sample()) == nil)
    }
}
