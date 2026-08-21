import Foundation

/// A JSON-RPC client over any `Transport`.
///
/// An actor rather than a locked class because request ids and in-flight state
/// are mutable and cross task boundaries; the compiler verifies the isolation
/// instead of taking a promise.
public actor JSONRPCConnection {
    private let transport: any Transport
    private let timeout: Duration
    private var nextID = 1

    /// - Parameter timeout: never defaulted at the call site. A hardcoded
    ///   timeout produces a test suite nobody runs.
    public init(transport: any Transport, timeout: Duration) {
        self.transport = transport
        self.timeout = timeout
    }

    public func call(_ method: String, _ params: RPCParams?) async throws -> RPCValue {
        let id = nextID
        nextID += 1
        let request = JSONRPCRequest(id: id, method: method, params: params)
        let line = try JSONEncoder().encode(request)

        let reply = try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { [transport] in
                try await transport.send(line)
                return try await transport.receiveLine()
            }
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                throw JSONRPCError.timedOut(method: method)
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }

        guard let reply else { throw JSONRPCError.connectionClosed }

        guard let response = try? JSONDecoder().decode(JSONRPCResponse.self, from: reply)
        else { throw JSONRPCError.malformedResponse }

        // A null id paired with an error is JSON-RPC 2.0's way of saying the
        // peer could not determine which request this was for (e.g. it could
        // not parse our request) — real information, not a mismatch. Any
        // other id mismatch, including a null id on a result, means we
        // cannot trust this reply is paired with our request at all, so it
        // is checked before looking at error/result.
        if !(response.id == nil && response.error != nil) {
            guard response.id == id else {
                throw JSONRPCError.idMismatch(expected: id, got: response.id)
            }
        }

        if let error = response.error {
            if error.code == JSONRPCError.methodNotFoundCode {
                throw JSONRPCError.methodNotFound(method)
            }
            throw JSONRPCError.remote(error)
        }

        guard let result = response.result else { throw JSONRPCError.malformedResponse }
        return result
    }
}
