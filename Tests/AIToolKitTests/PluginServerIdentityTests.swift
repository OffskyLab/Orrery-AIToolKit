import Foundation
import Testing
@testable import AIToolKit

/// Carrying the identity questions across the boundary.
///
/// The shape under test is the one thing a wire format can quietly get wrong
/// here: a listing's answers are **positional**, so anything that drops, sorts
/// or compacts them re-pairs every later row with the wrong directory. That
/// failure is invisible at the call site — every row still has an email on it.
@Suite("PluginServer identity")
struct PluginServerIdentityTests {

    private struct Reporting: AIToolIdentityReporting {
        let id = "reporting"
        let displayName = "Reporting"

        func listIdentities(in configDirs: [URL]) async throws -> [LoginIdentity?] {
            configDirs.map { dir in
                dir.lastPathComponent.hasPrefix("empty")
                    ? nil
                    : LoginIdentity(email: "\(dir.lastPathComponent)@example.com", plan: "Pro")
            }
        }

        func showIdentity(in configDir: URL) async throws -> LoginIdentity? {
            LoginIdentity(email: "fresh@example.com", plan: "Max")
        }
    }

    private struct Silent: AITool {
        let id = "silent"
        let displayName = "Silent"
    }

    private struct Failing: AIToolIdentityReporting {
        struct Boom: Error {}
        let id = "failing"
        let displayName = "Failing"
        func listIdentities(in configDirs: [URL]) async throws -> [LoginIdentity?] { throw Boom() }
        func showIdentity(in configDir: URL) async throws -> LoginIdentity? { throw Boom() }
    }

    private func reply(
        to method: String, params: RPCParams? = nil, tool: any AITool
    ) async throws -> JSONRPCResponse? {
        let req = JSONRPCRequest(id: 1, method: method, params: params)
        guard let out = await PluginServer.handle(line: try JSONEncoder().encode(req), tool: tool)
        else { return nil }
        return try JSONDecoder().decode(JSONRPCResponse.self, from: out)
    }

    @Test("capabilities advertise the identity methods only when the tool reports identities")
    func capabilitiesFollowConformance() async throws {
        let silent = try #require(try await reply(to: "initialize", tool: Silent()))
        guard case .object(let sr) = try #require(silent.result),
              case .object(let sc) = try #require(sr["capabilities"]) else {
            Issue.record("expected capabilities"); return
        }
        #expect(sc["tool/listIdentities"] == nil)
        #expect(sc["tool/showIdentity"] == nil)

        let reporting = try #require(try await reply(to: "initialize", tool: Reporting()))
        guard case .object(let rr) = try #require(reporting.result),
              case .object(let rc) = try #require(rr["capabilities"]) else {
            Issue.record("expected capabilities"); return
        }
        #expect(rc["tool/listIdentities"] == .bool(true))
        #expect(rc["tool/showIdentity"] == .bool(true))
    }

    @Test("a listing's answers come back positionally, gaps included")
    func listIsPositional() async throws {
        let res = try #require(try await reply(
            to: "tool/listIdentities",
            params: ["configDirs": .array([
                .string("/tmp/one"), .string("/tmp/empty-two"), .string("/tmp/three"),
            ])],
            tool: Reporting()))

        guard case .object(let obj) = try #require(res.result),
              case .array(let items) = try #require(obj["identities"]) else {
            Issue.record("expected an identities array"); return
        }

        // Three in, three out. A compacted array would leave two entries here and
        // hand "three@example.com" to the directory that has no login.
        #expect(items.count == 3)
        #expect(items[1] == .null, "the gap must survive as a gap")
        guard case .object(let first) = items[0], case .object(let third) = items[2] else {
            Issue.record("expected identity objects"); return
        }
        #expect(first["email"] == .string("one@example.com"))
        #expect(third["email"] == .string("three@example.com"))
    }

    @Test("an empty listing request is answered, not refused")
    func emptyListIsAnswered() async throws {
        let res = try #require(try await reply(
            to: "tool/listIdentities", params: ["configDirs": .array([])], tool: Reporting()))

        #expect(res.error == nil)
        guard case .object(let obj) = try #require(res.result),
              case .array(let items) = try #require(obj["identities"]) else {
            Issue.record("expected an identities array"); return
        }
        #expect(items.isEmpty)
    }

    @Test("a detail view answers for one directory")
    func showAnswers() async throws {
        let res = try #require(try await reply(
            to: "tool/showIdentity", params: ["configDir": .string("/tmp/x")], tool: Reporting()))

        guard case .object(let obj) = try #require(res.result),
              case .object(let identity) = try #require(obj["identity"]) else {
            Issue.record("expected an identity object"); return
        }
        #expect(identity["email"] == .string("fresh@example.com"))
        #expect(identity["plan"] == .string("Max"))
    }

    /// "No login here" is an answer. Reporting it as an error would make a host
    /// treat an ordinary, common state as a fault worth complaining about.
    @Test("no login in that directory is a null answer, not an error")
    func absentIdentityIsNull() async throws {
        struct None: AIToolIdentityReporting {
            let id = "none"
            let displayName = "None"
            func listIdentities(in configDirs: [URL]) async throws -> [LoginIdentity?] { [] }
            func showIdentity(in configDir: URL) async throws -> LoginIdentity? { nil }
        }

        let res = try #require(try await reply(
            to: "tool/showIdentity", params: ["configDir": .string("/tmp/x")], tool: None()))

        #expect(res.error == nil)
        guard case .object(let obj) = try #require(res.result) else {
            Issue.record("expected an object result"); return
        }
        #expect(obj["identity"] == .null)
    }

    @Test("a tool that does not report identities refuses the method")
    func silentToolRefuses() async throws {
        let res = try #require(try await reply(
            to: "tool/showIdentity", params: ["configDir": .string("/tmp/x")], tool: Silent()))

        #expect(res.result == nil)
        #expect(res.error?.code == JSONRPCError.methodNotFoundCode)
    }

    @Test("a lookup that throws is an error, not an absent identity")
    func failureIsNotAbsence() async throws {
        let res = try #require(try await reply(
            to: "tool/showIdentity", params: ["configDir": .string("/tmp/x")], tool: Failing()))

        #expect(res.result == nil)
        #expect(res.error?.code == JSONRPCError.operationFailedCode)
    }

    @Test("a missing configDir is refused rather than guessed at")
    func missingArgumentIsRefused() async throws {
        let res = try #require(try await reply(to: "tool/showIdentity", tool: Reporting()))

        #expect(res.result == nil)
        #expect(res.error?.code == JSONRPCError.invalidParamsCode)
    }
}
