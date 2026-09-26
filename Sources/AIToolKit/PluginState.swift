import Foundation

/// Where a plugin keeps what it owns.
///
/// A plugin owns its accounts, which means it owns a layout on disk. It does not
/// own a *root*: the host hands one over, and everything beneath it is the
/// plugin's to arrange.
///
/// ## Why the host supplies it
///
/// A plugin must never work out its own home directory. The host resolves paths
/// against a seam it can redirect, and that seam does not cross a process
/// boundary — a plugin that called a home-deriving API would read the
/// developer's real config during an isolated test run, which is a family of bug
/// this project has paid for repeatedly. So the root arrives in the environment,
/// and a plugin that cannot find it says so rather than guessing.
///
/// The distinction is *derive* versus *receive*. Receiving a directory keeps the
/// host's isolation intact — an isolated run passes a temporary one.
public enum PluginState {

    /// The environment variable the host sets when it spawns a plugin.
    public static let directoryEnvVar = "ORRERY_PLUGIN_STATE_DIR"

    /// The directory this plugin may write under.
    ///
    /// - Returns: `nil` when the host did not supply one. A plugin should treat
    ///   that as "I cannot store anything" and fail the operation, never as an
    ///   invitation to pick somewhere itself.
    public static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let path = environment[directoryEnvVar], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}
