import Foundation
import Testing
@testable import AIToolKit

@Suite("AITool")
struct AIToolTests {

    private var claude: AITool {
        AITool(
            id: "claude",
            displayName: "Claude Code",
            configDirectoryName: ".claude",
            configDirEnvVar: "CLAUDE_CONFIG_DIR",
            authLoginCommand: nil,
            installCommand: ["npm", "install", "-g", "@anthropic-ai/claude-code"],
            sessionSubdirectories: ["projects"],
            ansiColor: "\u{1B}[38;5;173m"
        )
    }

    @Test("identity is the id — two descriptions of the same tool are equal")
    func identityIsTheID() {
        var other = claude
        #expect(other == claude)
        #expect(Set([claude, other]).count == 1)

        other = AITool(
            id: "codex", displayName: "Claude Code",
            configDirectoryName: ".claude", configDirEnvVar: "CLAUDE_CONFIG_DIR",
            authLoginCommand: nil, installCommand: nil,
            sessionSubdirectories: [], ansiColor: ""
        )
        #expect(other != claude)
    }

    /// metadata.json stores `"tool": "claude"`. Encoding anything else would
    /// break every existing install.
    @Test("encodes as its bare id string")
    func encodesAsID() throws {
        let data = try JSONEncoder().encode(claude)
        #expect(String(data: data, encoding: .utf8) == "\"claude\"")
    }

    @Test("supportsSetup follows whether there is an install command")
    func supportsSetup() {
        #expect(claude.supportsSetup)

        let noInstall = AITool(
            id: "x", displayName: "X", configDirectoryName: ".x",
            configDirEnvVar: nil, authLoginCommand: nil, installCommand: nil,
            sessionSubdirectories: [], ansiColor: ""
        )
        #expect(!noInstall.supportsSetup)
    }

    /// gemini-cli ignores GEMINI_CONFIG_DIR and reads only $HOME/.gemini.
    /// Today's enum returns the variable name anyway, which is what sent
    /// `orrery add --gemini` at the user's real config. nil says so honestly;
    /// deciding to build a HOME wrapper instead is the host's business.
    @Test("a tool with no config-dir variable says so with nil")
    func noConfigDirEnvVar() {
        let gemini = AITool(
            id: "gemini", displayName: "Gemini CLI",
            configDirectoryName: ".gemini", configDirEnvVar: nil,
            authLoginCommand: nil, installCommand: nil,
            sessionSubdirectories: ["tmp"], ansiColor: ""
        )
        #expect(gemini.configDirEnvVar == nil)
    }

    @Test("coloredTag wraps the id in the tool's colour and resets")
    func coloredTag() {
        #expect(claude.coloredTag == "\u{1B}[38;5;173m[claude]\u{1B}[0m")
    }
}
