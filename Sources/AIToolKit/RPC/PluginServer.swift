import Foundation

/// The plugin side of the protocol. A plugin author implements ``AITool`` and
/// calls ``serve(tool:)``; the JSON-RPC loop is this package's problem.
public enum PluginServer {

    /// Bumped only on a breaking change. A host that does not recognise the
    /// major refuses the plugin with an explanation rather than guessing.
    public static let protocolVersion = "1"

    /// Answers one request line. Returns nil when the line is not a request
    /// worth answering — an unparseable line is skipped, never fatal, because
    /// stdout carries the protocol and a stray write must not end the session.
    public static func handle(line: Data, tool: any AITool) -> Data? {
        guard let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: line)
        else { return nil }

        let response: JSONRPCResponse
        switch request.method {
        case "initialize":
            response = JSONRPCResponse(id: request.id, result: .object([
                "protocolVersion": .string(protocolVersion),
                "capabilities": .object(["tool/describe": .bool(true)]),
            ]), error: nil)

        case "tool/describe":
            let d = ToolDescription(tool)
            response = JSONRPCResponse(id: request.id, result: .object([
                "id": .string(d.id),
                "displayName": .string(d.displayName),
                "configDirectoryName": .string(d.configDirectoryName),
                "configDirEnvVar": d.configDirEnvVar.map(RPCValue.string) ?? .null,
                "authLoginCommand": d.authLoginCommand.map { .array($0.map(RPCValue.string)) } ?? .null,
                "installCommand": d.installCommand.map { .array($0.map(RPCValue.string)) } ?? .null,
                "sessionSubdirectories": .array(d.sessionSubdirectories.map(RPCValue.string)),
                "ansiColor": .string(d.ansiColor),
            ]), error: nil)

        default:
            response = JSONRPCResponse(
                id: request.id, result: nil,
                error: .init(code: JSONRPCError.methodNotFoundCode,
                             message: "Method not found: \(request.method)"))
        }

        return try? JSONEncoder().encode(response)
    }

    /// Reads requests from stdin and writes replies to stdout until stdin closes.
    ///
    /// Anything a plugin wants to say to a human goes to stderr: stdout belongs
    /// to the protocol, and a stray `print` there desynchronises the stream.
    public static func serve(tool: any AITool) {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard let out = handle(line: Data(line.utf8), tool: tool) else { continue }
            FileHandle.standardOutput.write(out)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}
