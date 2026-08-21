import Foundation
import Testing
@testable import AIToolKit

@Suite("JSONRPCMessage")
struct JSONRPCMessageTests {

    @Test("a request encodes with jsonrpc 2.0 and its id")
    func requestEncodes() throws {
        let req = JSONRPCRequest(id: 7, method: "tool/describe", params: nil)
        let data = try JSONEncoder().encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["jsonrpc"] as? String == "2.0")
        #expect(obj["id"] as? Int == 7)
        #expect(obj["method"] as? String == "tool/describe")
    }

    @Test("a result response decodes and carries its id")
    func resultDecodes() throws {
        let line = #"{"jsonrpc":"2.0","id":7,"result":{"id":"claude"}}"#
        let res = try JSONDecoder().decode(JSONRPCResponse.self, from: Data(line.utf8))
        #expect(res.id == 7)
        #expect(res.error == nil)
        #expect(res.result != nil)
    }

    @Test("an error response decodes its code and message")
    func errorDecodes() throws {
        let line = #"{"jsonrpc":"2.0","id":7,"error":{"code":-32601,"message":"Method not found: x"}}"#
        let res = try JSONDecoder().decode(JSONRPCResponse.self, from: Data(line.utf8))
        #expect(res.error?.code == -32601)
        #expect(res.error?.message == "Method not found: x")
        #expect(res.result == nil)
    }
}
