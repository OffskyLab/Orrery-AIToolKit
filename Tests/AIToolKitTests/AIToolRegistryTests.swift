import Foundation
import Testing
@testable import AIToolKit

@Suite("AIToolRegistry")
struct AIToolRegistryTests {

    private struct TestTool: AITool {
        let id: String
        var displayName: String
        var configDirEnvVar: String?
    }

    private func tool(_ id: String) -> TestTool {
        TestTool(id: id, displayName: id)
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

    /// A registry holds `any AITool`, so what comes back out has to still carry
    /// the conformer's own answers — including the ones it left to the defaults.
    @Test("a conformer survives the round trip through the registry")
    func conformerRoundTrips() {
        let registry = AIToolRegistry()
        registry.register(TestTool(id: "codex", displayName: "Codex CLI"))

        let recovered = registry.tool(id: "codex")
        #expect(recovered?.id == "codex")
        #expect(recovered?.displayName == "Codex CLI")
        #expect(recovered?.configDirectoryName == ".codex")
        #expect(recovered?.supportsSetup == false)
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
        registry.register(TestTool(
            id: "claude",
            displayName: "Claude Code",
            configDirEnvVar: "CLAUDE_CONFIG_DIR"
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
