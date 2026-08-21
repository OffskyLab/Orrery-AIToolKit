import Foundation
import Testing
@testable import AIToolKit

@Suite("JSONRPCConnection")
struct JSONRPCConnectionTests {

    /// Replies to any request with a fixed result object.
    private func echoing(result: RPCValue) -> InMemoryTransport {
        InMemoryTransport { line in
            guard let req = try? JSONDecoder().decode(JSONRPCRequest.self, from: line)
            else { return nil }
            let res = JSONRPCResponse(id: req.id, result: result, error: nil)
            return try? JSONEncoder().encode(res)
        }
    }

    @Test("a call returns the plugin's result")
    func callReturnsResult() async throws {
        let conn = JSONRPCConnection(
            transport: echoing(result: .object(["id": .string("claude")])),
            timeout: .milliseconds(200))
        let got = try await conn.call("tool/describe", nil)
        #expect(got == .object(["id": .string("claude")]))
    }

    @Test("-32601 surfaces as methodNotFound, not a generic failure")
    func methodNotFoundIsDistinct() async throws {
        let t = InMemoryTransport { line in
            let req = try! JSONDecoder().decode(JSONRPCRequest.self, from: line)
            let res = JSONRPCResponse(
                id: req.id, result: nil,
                error: .init(code: -32601, message: "Method not found: \(req.method)"))
            return try? JSONEncoder().encode(res)
        }
        let conn = JSONRPCConnection(transport: t, timeout: .milliseconds(200))
        await #expect(throws: JSONRPCError.methodNotFound("tool/nope")) {
            try await conn.call("tool/nope", nil)
        }
    }

    @Test("a handler that never answers trips the injected timeout")
    func timeoutFires() async throws {
        let t = InMemoryTransport { _ in
            try? await Task.sleep(for: .seconds(30))
            return nil
        }
        let conn = JSONRPCConnection(transport: t, timeout: .milliseconds(50))
        await #expect(throws: JSONRPCError.timedOut(method: "tool/describe")) {
            try await conn.call("tool/describe", nil)
        }
    }

    @Test("a non-JSON line is a malformed response, not a crash")
    func garbageIsHandled() async throws {
        let t = InMemoryTransport { _ in Data("not json at all".utf8) }
        let conn = JSONRPCConnection(transport: t, timeout: .milliseconds(200))
        await #expect(throws: JSONRPCError.malformedResponse) {
            try await conn.call("tool/describe", nil)
        }
    }

    @Test("a closed pipe is reported as closed")
    func closedPipe() async throws {
        let t = InMemoryTransport { _ in nil }
        let conn = JSONRPCConnection(transport: t, timeout: .milliseconds(200))
        await #expect(throws: JSONRPCError.connectionClosed) {
            try await conn.call("tool/describe", nil)
        }
    }
}
