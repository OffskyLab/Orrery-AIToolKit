import Foundation

/// One AI CLI tool's description of itself.
///
/// Everything here is a *fact about the tool*: where it keeps its config, how
/// it logs in, how it is installed. Nothing here is a decision the host makes
/// about the tool — account pooling, credential storage policy and directory
/// sharing are the host's inventions, and belong to it.
///
/// Identity is `id`, which is also the on-disk representation: this type
/// encodes as a bare string so a host can keep writing `"tool": "claude"`.
public struct AITool: Sendable, Hashable, Codable {

    /// Stable identifier. Also the on-disk value and, typically, the directory
    /// segment a host uses for this tool.
    public let id: String

    /// Human-facing name, e.g. "Claude Code".
    public let displayName: String

    /// The directory name the tool reads its config from, e.g. `".claude"`.
    ///
    /// A name rather than a resolved `URL` on purpose: resolving it requires a
    /// home directory, and which home to resolve against is the host's
    /// decision — orrery redirects it in tests. A URL here would pull that
    /// policy into the framework.
    public let configDirectoryName: String

    /// The environment variable that relocates the tool's config directory, or
    /// `nil` if the tool has none.
    ///
    /// `nil` is a real answer, not a missing one. gemini-cli ignores
    /// `GEMINI_CONFIG_DIR` entirely and reads only `$HOME/.gemini`; claiming
    /// otherwise is what sent one of orrery's login flows at the user's real
    /// config directory. What to do about a tool like that — redirect `HOME`,
    /// refuse to isolate it — is the host's call.
    public let configDirEnvVar: String?

    /// A scriptable login subcommand, or `nil` when the tool authenticates on
    /// first interactive launch instead.
    public let authLoginCommand: [String]?

    /// How to install the tool, or `nil` if the host cannot install it.
    public let installCommand: [String]?

    /// Subdirectories of the config directory holding session state.
    public let sessionSubdirectories: [String]

    /// ANSI escape prefix used when tagging this tool's output.
    public let ansiColor: String

    public init(
        id: String,
        displayName: String,
        configDirectoryName: String,
        configDirEnvVar: String?,
        authLoginCommand: [String]?,
        installCommand: [String]?,
        sessionSubdirectories: [String],
        ansiColor: String
    ) {
        self.id = id
        self.displayName = displayName
        self.configDirectoryName = configDirectoryName
        self.configDirEnvVar = configDirEnvVar
        self.authLoginCommand = authLoginCommand
        self.installCommand = installCommand
        self.sessionSubdirectories = sessionSubdirectories
        self.ansiColor = ansiColor
    }

    public var supportsSetup: Bool { installCommand != nil }

    public var coloredTag: String { "\(ansiColor)[\(id)]\u{1B}[0m" }

    // MARK: - Identity

    public static func == (lhs: AITool, rhs: AITool) -> Bool { lhs.id == rhs.id }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: - Codable
    //
    // Encodes as the bare id so a host's existing on-disk format survives
    // unchanged. Decoding yields an id-only value; a host that needs the full
    // description looks it up in its registry.

    public init(from decoder: any Decoder) throws {
        let id = try decoder.singleValueContainer().decode(String.self)
        self.init(
            id: id, displayName: id, configDirectoryName: ".\(id)",
            configDirEnvVar: nil, authLoginCommand: nil, installCommand: nil,
            sessionSubdirectories: [], ansiColor: ""
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}
