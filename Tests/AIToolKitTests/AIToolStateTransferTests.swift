import Foundation
import Testing
@testable import AIToolKit

/// The first *operation* in this package. Everything before it was a fact the
/// tool states about itself; these are things a host asks the tool to do.
///
/// A separate protocol rather than more requirements on ``AITool``, because a
/// default implementation would have to be a silent no-op — and a tool that
/// forgot to implement credential copying would then report success over a copy
/// that never happened. Absence has to be something a host can *see*, so it is
/// a conformance a host checks for, not a method that quietly does nothing.
@Suite("AIToolStateTransfer")
struct AIToolStateTransferTests {

    /// Codex and gemini reduce to almost exactly this: one named credential
    /// file. Claude does not, which is why the protocol takes an operation
    /// rather than a filename.
    private struct SingleFileTool: AIToolStateTransfer {
        let id = "single"
        let displayName = "Single File Tool"
        let credentialFile = "auth.json"

        func copyLoginState(from sourceDir: URL?, to targetDir: URL) async throws -> Bool {
            guard let sourceDir else { return false }
            let src = sourceDir.appendingPathComponent(credentialFile)
            guard FileManager.default.fileExists(atPath: src.path) else { return false }
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            let dst = targetDir.appendingPathComponent(credentialFile)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: src, to: dst)
            return true
        }

        func copyNonLoginSettings(from sourceDir: URL, to targetDir: URL) async throws {
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: sourceDir.path)) ?? []
            where name != credentialFile {
                try? FileManager.default.copyItem(
                    at: sourceDir.appendingPathComponent(name),
                    to: targetDir.appendingPathComponent(name))
            }
        }
    }

    private func makeDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("state-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a conforming tool is still an AITool")
    func refinesAITool() {
        let tool: any AITool = SingleFileTool()
        #expect(tool.id == "single")
        // The point of refining rather than standing alone: a host holds
        // `any AITool` from the registry and asks whether this one can be
        // driven, without a second lookup in a parallel table.
        #expect(tool is any AIToolStateTransfer)
    }

    @Test("login state moves between two directories the host chose")
    func copiesLoginState() async throws {
        let source = try makeDir(), target = try makeDir()
        defer { try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: target) }
        try Data("secret".utf8).write(to: source.appendingPathComponent("auth.json"))

        let copied = try await SingleFileTool().copyLoginState(from: source, to: target)

        #expect(copied)
        let landed = try String(
            contentsOf: target.appendingPathComponent("auth.json"), encoding: .utf8)
        #expect(landed == "secret")
    }

    /// `false` and a thrown error mean different things, and the distinction is
    /// the reason this returns a Bool at all instead of being `Void`-and-throws:
    /// a source that was never logged in is an ordinary answer, while a copy
    /// that started and failed is not. Collapsing them would make "nothing to
    /// copy" indistinguishable from "the credential may be half-written".
    @Test("a source with nothing to copy answers false rather than throwing")
    func nothingToCopyIsNotAnError() async throws {
        let source = try makeDir(), target = try makeDir()
        defer { try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: target) }

        let copied = try await SingleFileTool().copyLoginState(from: source, to: target)

        #expect(!copied)
        #expect(!FileManager.default.fileExists(
            atPath: target.appendingPathComponent("auth.json").path))
    }

    @Test("non-login settings copy without carrying the credential across")
    func copiesSettingsOnly() async throws {
        let source = try makeDir(), target = try makeDir()
        defer { try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: target) }
        try Data("secret".utf8).write(to: source.appendingPathComponent("auth.json"))
        try Data("dark".utf8).write(to: source.appendingPathComponent("theme.json"))

        try await SingleFileTool().copyNonLoginSettings(from: source, to: target)

        #expect(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("theme.json").path))
        #expect(!FileManager.default.fileExists(
            atPath: target.appendingPathComponent("auth.json").path),
                "settings and credentials are copied by separate calls so a host can order them; carrying the credential here would defeat that")
    }

    /// A plain `AITool` must remain legal — a tool orrery only lists, never
    /// drives, should not be forced to implement file copying.
    @Test("a tool that does not transfer state simply does not conform")
    func nonConformingToolIsStillValid() {
        struct DescribeOnly: AITool {
            let id = "describe-only"
            let displayName = "Describe Only"
        }
        let tool: any AITool = DescribeOnly()
        #expect(!(tool is any AIToolStateTransfer))
    }
}
