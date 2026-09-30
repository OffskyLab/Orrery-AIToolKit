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
            if tool is any AIToolIdentityReporting {
                capabilities["tool/listIdentities"] = .bool(true)
                capabilities["tool/showIdentity"] = .bool(true)
            }
            if tool is any AIToolAccounts {
                capabilities["tool/list"] = .bool(true)
                capabilities["tool/current"] = .bool(true)
                capabilities["tool/setCurrent"] = .bool(true)
                capabilities["tool/addAccount"] = .bool(true)
                capabilities["tool/deleteAccount"] = .bool(true)
                capabilities["tool/pin"] = .bool(true)
                capabilities["tool/adoptLogin"] = .bool(true)
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

        case "tool/listIdentities", "tool/showIdentity":
            guard let reporter = tool as? any AIToolIdentityReporting else {
                response = JSONRPCResponse(
                    id: request.id, result: nil,
                    error: .init(code: JSONRPCError.methodNotFoundCode,
                                 message: "Method not found: \(request.method)"))
                break
            }
            response = await report(request.method, on: reporter,
                                    params: request.params, id: request.id)

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

        case "tool/list", "tool/current", "tool/setCurrent",
             "tool/addAccount", "tool/deleteAccount", "tool/pin", "tool/adoptLogin":
            guard let accounts = tool as? any AIToolAccounts else {
                response = JSONRPCResponse(
                    id: request.id, result: nil,
                    error: .init(code: JSONRPCError.methodNotFoundCode,
                                 message: "Method not found: \(request.method)"))
                break
            }
            response = await account(request.method, on: accounts,
                                     params: request.params, id: request.id)

        default:
            response = JSONRPCResponse(
                id: request.id, result: nil,
                error: .init(code: JSONRPCError.methodNotFoundCode,
                             message: "Method not found: \(request.method)"))
        }

        return try? JSONEncoder().encode(response)
    }



    /// Answers one identity question.
    ///
    /// The listing's reply is an array positionally aligned with the request, and
    /// a directory with no login is `.null` *in place*. Compacting it would be the
    /// worst kind of wrong: every row after the gap still carries a plausible
    /// identity, just the wrong one, and nothing downstream can detect it.
    ///
    /// "No login here" is a result, not an error. A tool that *threw* while
    /// looking is the error — the same distinction `copyLoginState` draws between
    /// nothing-to-copy and a copy that failed.
    private static func report(
        _ method: String,
        on tool: any AIToolIdentityReporting,
        params: RPCParams?,
        id: Int
    ) async -> JSONRPCResponse {
        func encoded(_ identity: LoginIdentity?) -> RPCValue {
            guard let identity else { return .null }
            return .object([
                "email": identity.email.map(RPCValue.string) ?? .null,
                "plan": identity.plan.map(RPCValue.string) ?? .null,
            ])
        }
        func invalid(_ message: String) -> JSONRPCResponse {
            JSONRPCResponse(id: id, result: nil,
                            error: .init(code: JSONRPCError.invalidParamsCode, message: message))
        }

        do {
            switch method {
            case "tool/listIdentities":
                guard case .array(let raw)? = params?["configDirs"] else {
                    return invalid("\(method): configDirs is required")
                }
                var dirs: [URL] = []
                for entry in raw {
                    guard case .string(let path) = entry, !path.isEmpty else {
                        return invalid("\(method): every configDirs entry must be a path")
                    }
                    dirs.append(URL(fileURLWithPath: path))
                }
                let found = try await tool.listIdentities(in: dirs)
                // A tool that answered a different number of questions than it was
                // asked has produced an array the host cannot align. Refusing beats
                // passing on a silent off-by-one.
                guard found.count == dirs.count else {
                    return JSONRPCResponse(
                        id: id, result: nil,
                        error: .init(code: JSONRPCError.operationFailedCode,
                                     message: "\(method): asked about \(dirs.count) directories, got \(found.count) answers"))
                }
                return JSONRPCResponse(
                    id: id, result: .object(["identities": .array(found.map(encoded))]), error: nil)

            default:
                guard case .string(let path)? = params?["configDir"], !path.isEmpty else {
                    return invalid("\(method): configDir is required")
                }
                let found = try await tool.showIdentity(in: URL(fileURLWithPath: path))
                return JSONRPCResponse(
                    id: id, result: .object(["identity": encoded(found)]), error: nil)
            }
        } catch {
            return JSONRPCResponse(
                id: id, result: nil,
                error: .init(code: JSONRPCError.operationFailedCode,
                             message: "\(method) failed: \(error)"))
        }
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

    /// Runs one account operation and turns its outcome into a reply.
    ///
    /// Three shapes, and keeping them apart is the job. Arguments that do not
    /// permit the call are `invalidParams`. An ordinary empty answer — no
    /// accounts, nothing pinned — is a *successful* reply carrying `null` or an
    /// empty array. An operation that was attempted and failed is
    /// `operationFailed`. Collapsing the last two would leave a host unable to
    /// tell "nothing is pinned" from "the pin could not be read".
    private static func account(
        _ method: String,
        on tool: any AIToolAccounts,
        params: RPCParams?,
        id: Int
    ) async -> JSONRPCResponse {
        func invalid(_ message: String) -> JSONRPCResponse {
            JSONRPCResponse(id: id, result: nil,
                            error: .init(code: JSONRPCError.invalidParamsCode, message: message))
        }

        func encoded(_ account: Account?) -> RPCValue {
            guard let account else { return .null }
            return .object([
                "id": .string(account.id),
                "name": .string(account.name),
                "email": account.email.map(RPCValue.string) ?? .null,
                "plan": account.plan.map(RPCValue.string) ?? .null,
                // Explicit null, like the other optionals: an absent key cannot be
                // told apart from a reply that lost it, and "pinned nowhere" is a
                // real state a host renders differently from "unknown".
                "workspace": account.workspace.map(RPCValue.string) ?? .null,
            ])
        }

        /// The wire names an account; the protocol asks the account to act on
        /// itself. Resolving the id is therefore the server's step, and it is the
        /// only place `noSuchAccount` can now arise — every operation beyond it
        /// is called on an account already in hand.
        func resolve(_ accountID: AccountID, in tool: any AIToolAccounts) async throws -> any Account {
            guard let account = try await tool.list().first(where: { $0.id == accountID })
            else { throw AccountError.noSuchAccount(accountID) }
            return account
        }

        func requiredID() -> AccountID? {
            guard case .string(let value)? = params?["id"], !value.isEmpty else { return nil }
            return value
        }

        do {
            switch method {
            case "tool/list":
                let accounts = try await tool.list()
                return JSONRPCResponse(
                    id: id, result: .object(["accounts": .array(accounts.map(encoded))]), error: nil)

            case "tool/current":
                return JSONRPCResponse(
                    id: id, result: .object(["account": encoded(try await tool.current())]), error: nil)

            case "tool/setCurrent":
                guard let accountID = requiredID() else { return invalid("\(method): id is required") }
                try await resolve(accountID, in: tool).makeCurrent()
                return JSONRPCResponse(id: id, result: .object([:]), error: nil)

            case "tool/addAccount":
                guard let accountID = requiredID() else { return invalid("\(method): id is required") }
                guard case .string(let name)? = params?["name"], !name.isEmpty else {
                    return invalid("\(method): name is required")
                }
                let created = try await tool.addAccount(id: accountID, name: name)
                return JSONRPCResponse(id: id, result: .object(["account": encoded(created)]), error: nil)

            case "tool/adoptLogin":
                guard let accountID = requiredID() else { return invalid("\(method): id is required") }
                guard case .string(let path)? = params?["directory"], !path.isEmpty else {
                    return invalid("\(method): directory is required")
                }
                try await resolve(accountID, in: tool)
                    .adoptLogin(from: URL(fileURLWithPath: path))
                return JSONRPCResponse(id: id, result: .object([:]), error: nil)

            case "tool/pin":
                guard let accountID = requiredID() else { return invalid("\(method): id is required") }
                guard case .string(let workspace)? = params?["workspace"], !workspace.isEmpty else {
                    return invalid("\(method): workspace is required")
                }
                try await resolve(accountID, in: tool).pin(to: workspace)
                return JSONRPCResponse(id: id, result: .object([:]), error: nil)

            default:
                guard let accountID = requiredID() else { return invalid("\(method): id is required") }
                try await resolve(accountID, in: tool).delete()
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
