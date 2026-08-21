/// One AI CLI tool's description of itself.
///
/// Everything here is a *fact about the tool*: where it keeps its config, how
/// it logs in, how it is installed. Nothing here is a decision the host makes
/// about the tool — account pooling, credential storage policy and directory
/// sharing are the host's inventions, and belong to it.
///
/// A protocol rather than a struct: a tool plugin conforms a type of its own,
/// and the extension below means it only has to answer the questions that make
/// it different. Today every requirement is data, but a conformer that has to
/// *compute* an answer — or that later needs behaviour rather than data — can,
/// which a fixed set of stored properties would have foreclosed.
///
/// Identity is `id`. `Sendable` is the only conformance this protocol refines,
/// and the only one that has to hold: a registered tool is shared across
/// concurrency domains, so that one is load-bearing. `Codable`, `Hashable` and
/// `Equatable` are deliberately absent — nothing in this package serializes to
/// a wire format or uses a tool as a dictionary key.
///
/// ## Serialization is the host's job
///
/// `any AITool` could not be `Decodable` in any case. Decoding produces a
/// *concrete* type, and nothing in a serialized value says which one —
/// recovering it needs an id→type table, which is exactly what
/// ``AIToolRegistry`` already is. So a host that wants `"tool": "claude"` on
/// disk encodes the `id` and reads it back by looking that id up in its
/// registry. A placeholder-producing decoder in here would only hand callers a
/// value with an id and nothing else, dressed up as a real tool description.
public protocol AITool: Sendable {

    /// Stable identifier. Also the on-disk value and, typically, the directory
    /// segment a host uses for this tool.
    ///
    /// Must be non-empty and free of whitespace and newlines;
    /// ``AIToolRegistry/register(_:)`` rejects anything else rather than
    /// storing it.
    ///
    /// That restriction is not tidiness. An id is the *only* part of a tool
    /// description that leaves the process: hosts write it into line-based
    /// records and path-like locations, neither of which can represent these
    /// characters. An id containing a newline is read back as two records —
    /// orrery's per-tool migration flag stores one id per line, so an id of
    /// `"cursor\nclaude"` silently marks claude's one-shot migration complete
    /// on that machine, permanently. An id with a trailing space is written
    /// verbatim and read back trimmed, so it never matches itself and the
    /// migration it guards re-runs on every invocation, forever. Neither
    /// failure is visible where it is caused, which is why the framework that
    /// accepts ids it does not control refuses them at the boundary instead of
    /// leaving every host to rediscover the rule.
    var id: String { get }

    /// Human-facing name, e.g. "Claude Code".
    var displayName: String { get }

    /// The directory name the tool reads its config from, e.g. `".claude"`.
    ///
    /// A name rather than a resolved `URL` on purpose: resolving it requires a
    /// home directory, and which home to resolve against is the host's
    /// decision — orrery redirects it in tests. A URL here would pull that
    /// policy into the framework.
    var configDirectoryName: String { get }

    /// The environment variable that relocates the tool's config directory, or
    /// `nil` if the tool has none.
    ///
    /// `nil` is a real answer, not a missing one. gemini-cli ignores
    /// `GEMINI_CONFIG_DIR` entirely and reads only `$HOME/.gemini`; claiming
    /// otherwise is what sent one of orrery's login flows at the user's real
    /// config directory. What to do about a tool like that — redirect `HOME`,
    /// refuse to isolate it — is the host's call.
    var configDirEnvVar: String? { get }

    /// A scriptable login subcommand, or `nil` when the tool authenticates on
    /// first interactive launch instead.
    var authLoginCommand: [String]? { get }

    /// How to install the tool, or `nil` if the host cannot install it.
    var installCommand: [String]? { get }

    /// Subdirectories of the config directory holding session state.
    var sessionSubdirectories: [String] { get }

    /// ANSI escape prefix used when tagging this tool's output.
    var ansiColor: String { get }
}

// MARK: - Defaults

/// What a conformer gets for free.
///
/// A minimal tool answers `id` and `displayName` and stops there; everything
/// else has an honest default. Note that these are *defaults*, not fallbacks
/// for missing information — `nil` from `configDirEnvVar` means "this tool has
/// no such variable", which is the true answer for most tools.
extension AITool {

    /// Nearly every CLI keeps its config in a dot-directory named after itself.
    public var configDirectoryName: String { ".\(id)" }

    public var configDirEnvVar: String? { nil }

    public var authLoginCommand: [String]? { nil }

    public var installCommand: [String]? { nil }

    public var sessionSubdirectories: [String] { [] }

    public var ansiColor: String { "" }
}

// MARK: - Derived

/// Answers computed from the requirements above.
///
/// These are extension members rather than protocol requirements on purpose: a
/// conformer must not be able to claim `supportsSetup` while offering no
/// `installCommand` for the host to run.
extension AITool {

    public var supportsSetup: Bool { installCommand != nil }

    public var coloredTag: String { "\(ansiColor)[\(id)]\u{1B}[0m" }
}
