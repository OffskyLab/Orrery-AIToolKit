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
    func registerAndLookUp() throws {
        let registry = AIToolRegistry()
        try registry.register(tool("claude"))

        #expect(!registry.isEmpty)
        #expect(registry.tool(id: "claude")?.id == "claude")
        #expect(registry.tool(id: "codex") == nil)
    }

    /// A registry holds `any AITool`, so what comes back out has to still carry
    /// the conformer's own answers — including the ones it left to the defaults.
    @Test("a conformer survives the round trip through the registry")
    func conformerRoundTrips() throws {
        let registry = AIToolRegistry()
        try registry.register(TestTool(id: "codex", displayName: "Codex CLI"))

        let recovered = registry.tool(id: "codex")
        #expect(recovered?.id == "codex")
        #expect(recovered?.displayName == "Codex CLI")
        #expect(recovered?.configDirectoryName == ".codex")
        #expect(recovered?.supportsSetup == false)
    }

    /// Several call sites iterate tools to build user-facing output. Arbitrary
    /// order would make that output differ run to run.
    @Test("all is sorted by id regardless of registration order")
    func allIsSorted() throws {
        let registry = AIToolRegistry()
        try registry.register(tool("gemini"))
        try registry.register(tool("claude"))
        try registry.register(tool("codex"))

        #expect(registry.all.map(\.id) == ["claude", "codex", "gemini"])
    }

    @Test("registering the same id again replaces the description")
    func reregisterReplaces() throws {
        let registry = AIToolRegistry()
        try registry.register(tool("claude"))
        try registry.register(TestTool(
            id: "claude",
            displayName: "Claude Code",
            configDirEnvVar: "CLAUDE_CONFIG_DIR"
        ))

        #expect(registry.all.count == 1)
        #expect(registry.tool(id: "claude")?.displayName == "Claude Code")
        #expect(registry.tool(id: "claude")?.configDirEnvVar == "CLAUDE_CONFIG_DIR")
    }

    @Test("reset clears everything")
    func reset() throws {
        let registry = AIToolRegistry()
        try registry.register(tool("claude"))
        registry.reset()

        #expect(registry.isEmpty)
    }

    // MARK: - Id validation

    /// A well-formed id is the uninteresting case, asserted so the rejections
    /// below are known to be about the id and not about registration itself.
    @Test("a valid id registers without complaint")
    func validIDRegisters() throws {
        let registry = AIToolRegistry()
        try registry.register(tool("claude"))

        #expect(registry.tool(id: "claude")?.id == "claude")
    }

    /// An empty id names nothing and collides with the next empty one.
    @Test("an empty id is refused")
    func emptyIDIsRefused() {
        let registry = AIToolRegistry()

        #expect(throws: AIToolRegistry.RegistrationError.invalidID("", reason: .empty)) {
            try registry.register(tool(""))
        }
    }

    /// Hosts write ids into line-based records and path-like locations. None of
    /// these survives the round trip: a space is trimmed off on read, a newline
    /// splits one id into two records, a tab is both.
    @Test(
        "an id carrying whitespace or a newline is refused",
        arguments: ["a b", "a\nb", "a\tb", "cursor "]
    )
    func whitespaceIDIsRefused(id: String) {
        let registry = AIToolRegistry()

        #expect(
            throws: AIToolRegistry.RegistrationError.invalidID(
                id, reason: .containsWhitespaceOrNewline
            )
        ) {
            try registry.register(tool(id))
        }
    }

    /// Rejection must not be half-done. Validation runs before the lock, so
    /// there is no window in which the bad id was stored and then removed.
    @Test("a refused registration leaves the registry untouched")
    func refusedRegistrationChangesNothing() {
        let registry = AIToolRegistry()

        #expect(throws: AIToolRegistry.RegistrationError.self) {
            try registry.register(tool("cursor\nclaude"))
        }

        #expect(registry.isEmpty)
        #expect(registry.all.isEmpty)
        #expect(registry.tool(id: "claude") == nil)
        #expect(registry.tool(id: "cursor\nclaude") == nil)
    }
}
