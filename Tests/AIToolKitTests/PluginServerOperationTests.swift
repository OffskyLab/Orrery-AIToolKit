import Foundation
import Testing
@testable import AIToolKit

// MARK: - Operations, not just description

/// `tool/describe` answers from data the tool already holds. These methods ask
/// it to *do* something, which is the first time the protocol carries a side
/// effect — so what a host can tell about the outcome matters more here than it
/// did for a description.
@Suite("PluginServer operations")
struct PluginServerOperationTests {

    private struct DescribeOnly: AITool {
        let id = "describe-only"
        let displayName = "Describe Only"
    }

    private struct Transferring: AIToolStateTransfer {
        let id = "transferring"
        let displayName = "Transferring"

        func copyLoginState(from sourceDir: URL?, to targetDir: URL) async throws -> Bool {
            guard let sourceDir else { return false }
            let src = sourceDir.appendingPathComponent("auth.json")
            guard FileManager.default.fileExists(atPath: src.path) else { return false }
            try FileManager.default.createDirectory(
                at: targetDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: src, to: targetDir.appendingPathComponent("auth.json"))
            return true
        }

        func copyNonLoginSettings(from sourceDir: URL, to targetDir: URL) async throws {
            try FileManager.default.createDirectory(
                at: targetDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: sourceDir.appendingPathComponent("theme.json"),
                to: targetDir.appendingPathComponent("theme.json"))
        }
    }

    private func reply(
        to method: String, params: RPCParams? = nil, tool: any AITool
    ) async throws -> JSONRPCResponse? {
        let req = JSONRPCRequest(id: 1, method: method, params: params)
        let line = try JSONEncoder().encode(req)
        guard let out = await PluginServer.handle(line: line, tool: tool) else { return nil }
        return try JSONDecoder().decode(JSONRPCResponse.self, from: out)
    }

    private func makeDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plugin-op-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Capabilities are how a host learns what it may ask for. Advertising a
    /// method the tool cannot perform would push the discovery to the first
    /// call, which for these methods is a call with side effects.
    @Test("capabilities advertise the operations only when the tool can perform them")
    func capabilitiesFollowConformance() async throws {
        let plain = try #require(try await reply(to: "initialize", tool: DescribeOnly()))
        guard case .object(let plainResult) = try #require(plain.result),
              case .object(let plainCaps) = try #require(plainResult["capabilities"])
        else { Issue.record("expected capabilities object"); return }
        #expect(plainCaps["tool/describe"] == .bool(true))
        #expect(plainCaps["tool/copyLoginState"] == nil)
        #expect(plainCaps["tool/copyNonLoginSettings"] == nil)

        let full = try #require(try await reply(to: "initialize", tool: Transferring()))
        guard case .object(let fullResult) = try #require(full.result),
              case .object(let fullCaps) = try #require(fullResult["capabilities"])
        else { Issue.record("expected capabilities object"); return }
        #expect(fullCaps["tool/copyLoginState"] == .bool(true))
        #expect(fullCaps["tool/copyNonLoginSettings"] == .bool(true))
    }

    @Test("copyLoginState performs the copy and reports that it happened")
    func copyLoginStateWorks() async throws {
        let source = try makeDir(), target = try makeDir()
        defer { try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: target) }
        try Data("secret".utf8).write(to: source.appendingPathComponent("auth.json"))

        let res = try #require(try await reply(
            to: "tool/copyLoginState",
            params: ["sourceDir": .string(source.path), "targetDir": .string(target.path)],
            tool: Transferring()))

        guard case .object(let obj) = try #require(res.result) else {
            Issue.record("expected an object result"); return
        }
        #expect(obj["copied"] == .bool(true))
        // The reply is not the assertion — the file is. A method that reported
        // success without copying would satisfy the line above.
        #expect(FileManager.default.contents(
            atPath: target.appendingPathComponent("auth.json").path) == Data("secret".utf8))
    }

    /// `false` crosses the wire as an answer, not as an error: a source that was
    /// never logged in is an ordinary outcome, and a host that saw an error here
    /// could not tell it apart from a copy that failed halfway.
    @Test("nothing to copy crosses the wire as false, not as an error")
    func nothingToCopyIsAnAnswer() async throws {
        let source = try makeDir(), target = try makeDir()
        defer { try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: target) }

        let res = try #require(try await reply(
            to: "tool/copyLoginState",
            params: ["sourceDir": .string(source.path), "targetDir": .string(target.path)],
            tool: Transferring()))

        #expect(res.error == nil)
        guard case .object(let obj) = try #require(res.result) else {
            Issue.record("expected an object result"); return
        }
        #expect(obj["copied"] == .bool(false))
    }

    /// `nil` is a real argument — "your own default location" — and has to
    /// survive the crossing as itself rather than as a missing key.
    @Test("a null sourceDir reaches the tool as nil")
    func nullSourceDirIsPreserved() async throws {
        let target = try makeDir()
        defer { try? FileManager.default.removeItem(at: target) }

        let res = try #require(try await reply(
            to: "tool/copyLoginState",
            params: ["sourceDir": .null, "targetDir": .string(target.path)],
            tool: Transferring()))

        guard case .object(let obj) = try #require(res.result) else {
            Issue.record("expected an object result"); return
        }
        // Transferring answers false for a nil source, so this distinguishes
        // "nil arrived" from "an empty path arrived".
        #expect(obj["copied"] == .bool(false))
        #expect(res.error == nil)
    }

    @Test("copyNonLoginSettings performs the copy")
    func copySettingsWorks() async throws {
        let source = try makeDir(), target = try makeDir()
        defer { try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: target) }
        try Data("dark".utf8).write(to: source.appendingPathComponent("theme.json"))

        let res = try #require(try await reply(
            to: "tool/copyNonLoginSettings",
            params: ["sourceDir": .string(source.path), "targetDir": .string(target.path)],
            tool: Transferring()))

        #expect(res.error == nil)
        #expect(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("theme.json").path))
    }

    @Test("a tool that cannot transfer state refuses the method")
    func nonConformingToolRefuses() async throws {
        let res = try #require(try await reply(
            to: "tool/copyLoginState",
            params: ["sourceDir": .null, "targetDir": .string("/tmp")],
            tool: DescribeOnly()))

        #expect(res.result == nil)
        #expect(res.error?.code == JSONRPCError.methodNotFoundCode,
                "the method genuinely is not offered — initialize said so")
    }

    /// A failed copy must not come back as a successful one. The tool throws;
    /// the host has to see an error rather than `copied: false`, which would
    /// read as "there was nothing to copy".
    @Test("a copy that fails partway comes back as an error, not as false")
    func failureIsNotConfusedWithNothingToDo() async throws {
        struct Failing: AIToolStateTransfer {
            struct Boom: Error {}
            let id = "failing"
            let displayName = "Failing"
            func copyLoginState(from sourceDir: URL?, to targetDir: URL) async throws -> Bool {
                throw Boom()
            }
            func copyNonLoginSettings(from sourceDir: URL, to targetDir: URL) async throws {
                throw Boom()
            }
        }

        let res = try #require(try await reply(
            to: "tool/copyLoginState",
            params: ["sourceDir": .string("/tmp"), "targetDir": .string("/tmp/x")],
            tool: Failing()))

        #expect(res.result == nil)
        #expect(res.error != nil)
    }

    @Test("a missing targetDir is refused rather than guessed at")
    func missingTargetIsRefused() async throws {
        let res = try #require(try await reply(
            to: "tool/copyLoginState",
            params: ["sourceDir": .null],
            tool: Transferring()))

        #expect(res.result == nil)
        #expect(res.error != nil, "a copy with no destination has no sensible default")
    }
}
