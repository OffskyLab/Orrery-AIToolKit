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
    /// `async` because the operations below are: a tool asked to copy its login
    /// state does real work, and unlike `tool/describe` the answer cannot come
    /// from data already in hand.
    public static func handle(line: Data, tool: any AITool) async -> Data? {
        guard let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: line)
        else { return nil }

        let response: JSONRPCResponse
        switch request.method {
        case "initialize":
            // Capabilities follow conformance rather than being a fixed list.
            // Advertising a method the tool cannot perform would defer the
            // discovery to the first call — and for these methods, the first
            // call is one with side effects.
            var capabilities: [String: RPCValue] = ["tool/describe": .bool(true)]
            if tool is any AIToolStateTransfer {
                capabilities["tool/copyLoginState"] = .bool(true)
                capabilities["tool/copyNonLoginSettings"] = .bool(true)
            }
            response = JSONRPCResponse(id: request.id, result: .object([
                "protocolVersion": .string(protocolVersion),
                "capabilities": .object(capabilities),
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

        case "tool/copyLoginState", "tool/copyNonLoginSettings":
            // A tool that does not conform genuinely does not offer these, and
            // said so at `initialize`. Method-not-found is the honest answer;
            // inventing a no-op success would be the failure this package keeps
            // legislating against — work reported as done that never happened.
            guard let transfer = tool as? any AIToolStateTransfer else {
                response = JSONRPCResponse(
                    id: request.id, result: nil,
                    error: .init(code: JSONRPCError.methodNotFoundCode,
                                 message: "Method not found: \(request.method)"))
                break
            }
            response = await perform(request.method, on: transfer, params: request.params, id: request.id)

        default:
            response = JSONRPCResponse(
                id: request.id, result: nil,
                error: .init(code: JSONRPCError.methodNotFoundCode,
                             message: "Method not found: \(request.method)"))
        }

        return try? JSONEncoder().encode(response)
    }


    /// Runs one state-transfer operation and turns its outcome into a reply.
    ///
    /// Three outcomes, three shapes, and keeping them apart is the whole job:
    /// arguments that do not permit the call are `invalidParams`, a copy that
    /// found nothing to do is a *successful* reply carrying `copied: false`, and
    /// a copy that was attempted and threw is `operationFailed`. Collapsing the
    /// last two would leave a host unable to tell "the source was never logged
    /// in" from "the credential may be half-written".
    private static func perform(
        _ method: String,
        on tool: any AIToolStateTransfer,
        params: RPCParams?,
        id: Int
    ) async -> JSONRPCResponse {
        func invalid(_ message: String) -> JSONRPCResponse {
            JSONRPCResponse(id: id, result: nil,
                            error: .init(code: JSONRPCError.invalidParamsCode, message: message))
        }

        guard case .string(let targetPath)? = params?["targetDir"], !targetPath.isEmpty else {
            return invalid("\(method): targetDir is required")
        }
        let target = URL(fileURLWithPath: targetPath)

        do {
            switch method {
            case "tool/copyLoginState":
                // A `null` sourceDir is a real argument — "your own default
                // location" — and a missing key is not the same thing. Both
                // arrive as nil here, which is the one place this is lenient:
                // the alternative is refusing a request whose intent is clear.
                var source: URL?
                if case .string(let sourcePath)? = params?["sourceDir"], !sourcePath.isEmpty {
                    source = URL(fileURLWithPath: sourcePath)
                }
                let copied = try await tool.copyLoginState(from: source, to: target)
                return JSONRPCResponse(id: id, result: .object(["copied": .bool(copied)]), error: nil)

            default:
                guard case .string(let sourcePath)? = params?["sourceDir"], !sourcePath.isEmpty else {
                    return invalid("\(method): sourceDir is required")
                }
                try await tool.copyNonLoginSettings(
                    from: URL(fileURLWithPath: sourcePath), to: target)
                return JSONRPCResponse(id: id, result: .object([:]), error: nil)
            }
        } catch {
            return JSONRPCResponse(
                id: id, result: nil,
                error: .init(code: JSONRPCError.operationFailedCode,
                             message: "\(method) failed: \(error)"))
        }
    }

    /// Reads requests from stdin and writes replies to stdout until stdin closes.
    ///
    /// Anything a plugin wants to say to a human goes to stderr: stdout belongs
    /// to the protocol, and a stray `print` there desynchronises the stream.
    /// `async` follows `handle`. A plugin's `main.swift` is top-level code,
    /// where `await` is allowed, so this costs a keyword at the call site and
    /// nothing else.
    public static func serve(tool: any AITool) async {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard let out = await handle(line: Data(line.utf8), tool: tool) else { continue }
            // The throwing variant, not `write(_:)`: on a closed pipe (the
            // host has exited mid-reply) `write(_:)` raises an Objective-C
            // exception that Swift cannot catch, taking the plugin down
            // with a crash report over something that is not a bug — the
            // host is simply gone. `write(contentsOf:)` reports the same
            // condition as a thrown Swift error instead, which is caught
            // below and treated as the ordinary end of the session.
            do {
                try FileHandle.standardOutput.write(contentsOf: out)
                try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
            } catch {
                break
            }
        }
    }
}
