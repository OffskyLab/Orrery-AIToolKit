import Foundation

/// Who a config directory is logged in as, as the tool understands it.
///
/// Both fields are optional and mean "the tool could not say", which is distinct
/// from the whole value being `nil` — that means the tool found no login here at
/// all. A host renders the two the same way and must not conflate them when
/// deciding whether to ask again.
///
/// Deliberately not an "account": an account is the host's invention — a pooled,
/// named, switchable thing. A tool knows only that some directory carries a login.
public struct LoginIdentity: Sendable, Equatable, Codable {
    public let email: String?
    public let plan: String?

    public init(email: String?, plan: String?) {
        self.email = email
        self.plan = plan
    }
}

/// A tool that can say who its config directories are logged in as.
///
/// Two methods, and they exist because two host features ask different
/// questions — not because one capability was split in half.
///
/// - A listing asks about **many** directories and wants a **cheap** answer.
/// - A detail view asks about **one** and wants the **freshest**.
///
/// They may well return the same fields. What differs is what the tool is
/// allowed to spend getting them, and that is a decision only the tool can make:
/// which of its sources is authoritative, and what it costs to consult, is
/// knowledge about its own storage.
///
/// The alternative — one method plus a `wantsFreshData` flag — puts the host in
/// charge of how hard the tool works, which is precisely the leak this replaces.
/// orrery's own version of that flag (`isLiveInThisShell`) is what prompted the
/// split.
public protocol AIToolIdentityReporting: AITool {

    /// Identities for a listing, cheapest source the tool considers acceptable.
    ///
    /// - Returns: one element per input, **positionally**, with `nil` where that
    ///   directory carries no login. Positional rather than keyed because the
    ///   host has to line the answers back up with what it asked about; a
    ///   shorter array would silently shift every row after a gap.
    func listIdentities(in configDirs: [URL]) async throws -> [LoginIdentity?]

    /// The freshest identity the tool can obtain for one directory.
    ///
    /// - Returns: `nil` when the directory carries no login at all.
    func showIdentity(in configDir: URL) async throws -> LoginIdentity?
}
