import Foundation
import Testing
@testable import AIToolKit

@Suite("AIToolRegistry")
struct AIToolRegistryTests {

    private func tool(_ id: String) -> AITool {
        AITool(
            id: id, displayName: id, configDirectoryName: ".\(id)",
            configDirEnvVar: nil, authLoginCommand: nil, installCommand: nil,
            sessionSubdirectories: [], ansiColor: ""
        )
    }

    @Test("a fresh registry knows nothing")
    func startsEmpty() {
        let registry = AIToolRegistry()
        #expect(registry.isEmpty)
        #expect(registry.all.isEmpty)
        #expect(registry.tool(id: "claude") == nil)
    }

    @Test("registered tools are retrievable by id")
    func registerAndLookUp() {
        let registry = AIToolRegistry()
        registry.register(tool("claude"))

        #expect(!registry.isEmpty)
        #expect(registry.tool(id: "claude")?.id == "claude")
        #expect(registry.tool(id: "codex") == nil)
    }

    /// Several call sites iterate tools to build user-facing output. Arbitrary
    /// order would make that output differ run to run.
    @Test("all is sorted by id regardless of registration order")
    func allIsSorted() {
        let registry = AIToolRegistry()
        registry.register(tool("gemini"))
        registry.register(tool("claude"))
        registry.register(tool("codex"))

        #expect(registry.all.map(\.id) == ["claude", "codex", "gemini"])
    }

    @Test("registering the same id again replaces the description")
    func reregisterReplaces() {
        let registry = AIToolRegistry()
        registry.register(tool("claude"))
        registry.register(AITool(
            id: "claude", displayName: "Claude Code",
            configDirectoryName: ".claude", configDirEnvVar: "CLAUDE_CONFIG_DIR",
            authLoginCommand: nil, installCommand: nil,
            sessionSubdirectories: [], ansiColor: ""
        ))

        #expect(registry.all.count == 1)
        #expect(registry.tool(id: "claude")?.displayName == "Claude Code")
        #expect(registry.tool(id: "claude")?.configDirEnvVar == "CLAUDE_CONFIG_DIR")
    }

    @Test("reset clears everything")
    func reset() {
        let registry = AIToolRegistry()
        registry.register(tool("claude"))
        registry.reset()

        #expect(registry.isEmpty)
    }
}
