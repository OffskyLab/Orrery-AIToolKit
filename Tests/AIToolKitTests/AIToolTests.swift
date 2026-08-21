import Foundation
import Testing
@testable import AIToolKit

@Suite("AITool")
struct AIToolTests {

    /// The whole point of the protocol: a conformer that answers only the two
    /// questions no default can answer for it.
    private struct MinimalTool: AITool {
        let id: String
        let displayName: String
    }

    /// A conformer that overrides every requirement, so the defaults must not
    /// win anywhere.
    private struct ClaudeTool: AITool {
        let id = "claude"
        let displayName = "Claude Code"
        let configDirectoryName = ".claude-custom"
        let configDirEnvVar: String? = "CLAUDE_CONFIG_DIR"
        let authLoginCommand: [String]? = ["claude", "auth", "login"]
        let installCommand: [String]? = ["npm", "install", "-g", "@anthropic-ai/claude-code"]
        let sessionSubdirectories = ["projects"]
        let ansiColor = "\u{1B}[38;5;173m"
    }

    /// Everything a conformer does not say is answered for it. Pinning each
    /// default individually because these are the promise the protocol makes to
    /// a plugin author — silently changing one would change what their type
    /// means without touching their code.
    @Test("a minimal conformer gets every default")
    func minimalConformerGetsDefaults() {
        let tool = MinimalTool(id: "codex", displayName: "Codex CLI")

        #expect(tool.configDirectoryName == ".codex")
        #expect(tool.configDirEnvVar == nil)
        #expect(tool.authLoginCommand == nil)
        #expect(tool.installCommand == nil)
        #expect(tool.sessionSubdirectories == [])
        #expect(tool.ansiColor == "")
    }

    /// `configDirectoryName` is derived from `id`, so it has to follow the
    /// conformer rather than be fixed at any one value.
    @Test("the default config directory name follows the id")
    func defaultConfigDirectoryNameFollowsID() {
        #expect(MinimalTool(id: "gemini", displayName: "Gemini CLI").configDirectoryName == ".gemini")
        #expect(MinimalTool(id: "aider", displayName: "Aider").configDirectoryName == ".aider")
    }

    @Test("a full conformer keeps its own values, not the defaults")
    func fullConformerOverridesDefaults() {
        let claude = ClaudeTool()

        #expect(claude.id == "claude")
        #expect(claude.displayName == "Claude Code")
        #expect(claude.configDirectoryName == ".claude-custom")
        #expect(claude.configDirEnvVar == "CLAUDE_CONFIG_DIR")
        #expect(claude.authLoginCommand == ["claude", "auth", "login"])
        #expect(claude.installCommand == ["npm", "install", "-g", "@anthropic-ai/claude-code"])
        #expect(claude.sessionSubdirectories == ["projects"])
        #expect(claude.ansiColor == "\u{1B}[38;5;173m")
    }

    /// The defaults survive being reached through the existential too — a host
    /// holds `any AITool`, never the concrete type.
    @Test("defaults apply through the existential")
    func defaultsApplyThroughExistential() {
        let tool: any AITool = MinimalTool(id: "codex", displayName: "Codex CLI")

        #expect(tool.configDirectoryName == ".codex")
        #expect(tool.installCommand == nil)
    }

    @Test("supportsSetup follows whether there is an install command")
    func supportsSetup() {
        #expect(ClaudeTool().supportsSetup)
        #expect(!MinimalTool(id: "x", displayName: "X").supportsSetup)
    }

    /// gemini-cli ignores GEMINI_CONFIG_DIR and reads only $HOME/.gemini.
    /// An enum that returned the variable name anyway is what sent
    /// `orrery add --gemini` at the user's real config. nil says so honestly,
    /// and is what a conformer gets without asking; deciding to build a HOME
    /// wrapper instead is the host's business.
    @Test("a tool with no config-dir variable says so with nil")
    func noConfigDirEnvVar() {
        let gemini = MinimalTool(id: "gemini", displayName: "Gemini CLI")
        #expect(gemini.configDirEnvVar == nil)
    }

    @Test("coloredTag wraps the id in the tool's colour and resets")
    func coloredTag() {
        #expect(ClaudeTool().coloredTag == "\u{1B}[38;5;173m[claude]\u{1B}[0m")
    }

    /// With no colour of its own a tag is still well-formed — just uncoloured.
    @Test("coloredTag with the default colour is still a bracketed id")
    func coloredTagWithDefaultColor() {
        #expect(MinimalTool(id: "codex", displayName: "Codex CLI").coloredTag == "[codex]\u{1B}[0m")
    }
}
