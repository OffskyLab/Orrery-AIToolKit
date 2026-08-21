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
        #expect(res.result == .object(["id": .string("claude")]))
    }

    @Test("an error response decodes its code and message")
    func errorDecodes() throws {
        let line = #"{"jsonrpc":"2.0","id":7,"error":{"code":-32601,"message":"Method not found: x"}}"#
        let res = try JSONDecoder().decode(JSONRPCResponse.self, from: Data(line.utf8))
        #expect(res.error?.code == -32601)
        #expect(res.error?.message == "Method not found: x")
        #expect(res.result == nil)
    }

    @Test("a whole number survives the encode-decode round trip")
    func numberRoundTrip() throws {
        let value = RPCValue.number(7.0)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(RPCValue.self, from: data)
        #expect(decoded == .number(7.0))
    }

    @Test("a whole number nested in an object survives the round trip")
    func nestedNumberRoundTrip() throws {
        let value = RPCValue.object(["count": .number(42.0)])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(RPCValue.self, from: data)
        #expect(decoded == .object(["count": .number(42.0)]))
    }

    @Test("a response with null id decodes with id nil")
    func nullIdDecodes() throws {
        let line = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#
        let res = try JSONDecoder().decode(JSONRPCResponse.self, from: Data(line.utf8))
        #expect(res.id == nil)
        #expect(res.error?.code == -32700)
        #expect(res.error?.message == "Parse error")
    }
}
