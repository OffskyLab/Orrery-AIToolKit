import Foundation

/// A tool that can move its own state between two config directories.
///
/// The first *operation* in this package. Everything in ``AITool`` is a fact the
/// tool states about itself; these are things a host asks it to do. The split
/// the package's design rests on still holds: the tool knows *how* its login
/// state is stored and what counts as a credential, while the host decides
/// *which* directories are involved and when. Both parameters are plain
/// directory URLs for exactly that reason — a host's own vocabulary (accounts,
/// workspaces, an origin) has no business crossing into a tool.
///
/// ## Why a separate protocol
///
/// These could have been requirements on ``AITool`` with default
/// implementations. The default would have to be a silent no-op, and a tool
/// that simply forgot to implement credential copying would then let a host
/// report success over a copy that never happened. Absence has to be something
/// a host can *see*, so it is a conformance to check for rather than a method
/// that quietly does nothing. A tool a host only ever lists is a legal ``AITool``
/// and does not conform here.
///
/// ## Why `async`
///
/// Not for the sake of a plugin, which does local filesystem work and can
/// satisfy these without ever suspending. It is for the *host* side: when the
/// tool on the other end of the protocol is a separate process, every call is a
/// round trip. A synchronous requirement would leave a remote conformer
/// blocking a thread on a pipe, or unable to conform at all.
public protocol AIToolStateTransfer: AITool {

    /// Copy login state — credentials, and whatever identity config travels
    /// with them — from one config directory to another.
    ///
    /// - Parameters:
    ///   - sourceDir: the directory to copy from, or `nil` for the tool's own
    ///     default location. `nil` is not "unknown": a tool whose credentials
    ///     live outside any config directory, in a system keychain, needs a way
    ///     to say "the ambient one" that is distinct from a path.
    ///   - targetDir: the directory to copy into. Created if it does not exist.
    /// - Returns: `false` when there was nothing to copy, which is an ordinary
    ///   answer — a source that was never logged in.
    /// - Throws: when a copy was attempted and failed. Distinct from `false` on
    ///   purpose: collapsing the two would make "nothing to copy" and "the
    ///   credential may be half-written" indistinguishable to a host that has to
    ///   decide whether to carry on.
    func copyLoginState(from sourceDir: URL?, to targetDir: URL) async throws -> Bool

    /// Copy everything that is *not* login state — preferences, plugins, skills.
    ///
    /// A separate call from ``copyLoginState(from:to:)`` so a host can order the
    /// two. That ordering is not hypothetical: Claude Code mixes identity and
    /// preferences in one file, so settings must land first and the login copy
    /// must merge identity over them. A single combined call would have taken
    /// that choice away from the host.
    func copyNonLoginSettings(from sourceDir: URL, to targetDir: URL) async throws
}
