import Foundation
import Testing
@testable import AIToolKit

@Suite("ToolDescription")
struct ToolDescriptionTests {

    private struct Sample: AITool {
        let id = "claude"
        let displayName = "Claude Code"
        let configDirectoryName = ".claude"
        let configDirEnvVar: String? = "CLAUDE_CONFIG_DIR"
        let authLoginCommand: [String]? = nil
        let installCommand: [String]? = ["sh", "-c", "install.sh"]
        let sessionSubdirectories = ["projects"]
        let ansiColor = "\u{1B}[38;5;173m"
    }

    @Test("a description captures every field of the tool it was built from")
    func capturesAllFields() {
        let d = ToolDescription(Sample())
        #expect(d.id == "claude")
        #expect(d.displayName == "Claude Code")
        #expect(d.configDirectoryName == ".claude")
        #expect(d.configDirEnvVar == "CLAUDE_CONFIG_DIR")
        #expect(d.authLoginCommand == nil)
        #expect(d.installCommand == ["sh", "-c", "install.sh"])
        #expect(d.sessionSubdirectories == ["projects"])
        #expect(d.ansiColor == "\u{1B}[38;5;173m")
    }

    @Test("a description survives a round trip through JSON")
    func roundTrips() throws {
        let original = ToolDescription(Sample())
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(ToolDescription.self, from: data)
        #expect(back == original)
    }

    @Test("a nil optional stays nil across the wire, rather than becoming empty")
    func nilSurvives() throws {
        let data = try JSONEncoder().encode(ToolDescription(Sample()))
        let back = try JSONDecoder().decode(ToolDescription.self, from: data)
        #expect(back.authLoginCommand == nil)
    }
}
