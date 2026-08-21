import Foundation

/// A JSON value as it crosses the wire.
///
/// The protocol has to carry arbitrary params and results without this package
/// knowing their shapes, and `Any` is not `Sendable`. This closed enum is the
/// smallest thing that is both.
public enum RPCValue: Codable, Sendable, Equatable {
    case string(String)
    /// A JSON number. There is one number case because JSON has one number type,
    /// and a `.double`/`.int` split cannot round-trip: an integral double like `7.0`
    /// encodes to `7` (Foundation drops the fraction) and decodes back as `.int(7)`.
    case number(Double)
    case bool(Bool)
    case array([RPCValue])
    case object([String: RPCValue])
    case null

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([RPCValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: RPCValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "unrepresentable JSON value")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v):   try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null:          try c.encodeNil()
        }
    }
}

public typealias RPCParams = [String: RPCValue]

public struct JSONRPCRequest: Codable, Sendable {
    public let jsonrpc: String
    public let id: Int
    public let method: String
    public let params: RPCParams?

    public init(id: Int, method: String, params: RPCParams?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCErrorBody: Codable, Sendable, Equatable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public struct JSONRPCResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: Int?
    public let result: RPCValue?
    public let error: JSONRPCErrorBody?

    public init(id: Int?, result: RPCValue?, error: JSONRPCErrorBody?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }
}

/// Errors the client raises, as distinct from errors a plugin reports.
public enum JSONRPCError: Error, Equatable, Sendable {
    /// The plugin answered `-32601`. Treated as "capability absent", not failure.
    case methodNotFound(String)
    /// The plugin reported an application error.
    case remote(JSONRPCErrorBody)
    /// No reply within the injected timeout.
    case timedOut(method: String)
    /// The pipe closed while a call was in flight.
    case connectionClosed
    /// A reply arrived that was not a JSON-RPC response.
    case malformedResponse
    /// The peer answered with an id that was not the one asked. A plugin
    /// replying out of turn is a plugin bug, and accepting it silently would
    /// pair a reply with the wrong request.
    case idMismatch(expected: Int, got: Int?)

    public static let methodNotFoundCode = -32601
}
