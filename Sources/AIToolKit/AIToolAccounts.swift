import Foundation

/// A stable handle for one account, chosen by the host.
///
/// The host names accounts because it is the host a person is talking to; the
/// plugin stores what it is given. A plugin that minted its own ids would give a
/// host nothing to refer to an account by until after it had created one.
public typealias AccountID = String

/// One account, as both sides agree to describe it.
///
/// A protocol rather than a struct, for the reason ``AITool`` is one: holding
/// only properties today does not mean nothing will ever need behaviour here,
/// and a struct forces a breaking change the first time one does. It is also
/// what lets a forwarding proxy conform without carrying values it does not have.
///
/// Defined here rather than in the host or in a plugin, because neither owns it:
/// the host depends on this type, a plugin supplies values of it, and the
/// dependency runs from both sides inward.
///
/// ## What a conformer must supply
///
/// ``id`` and ``name``. Everything else defaults, so the smallest useful account
/// is two properties — that is the point of the protocol rather than decoration
/// on it.
///
/// ## The workspace an account is pinned to
///
/// An account carries its own workspace rather than the plugin keeping a table
/// keyed the other way. The relation is one workspace per account, so the account
/// is where it belongs, and a host that wants the accounts of one workspace
/// filters a listing instead of asking a second question.
///
/// `nil` means not pinned to any. The framework has no default: "the first one",
/// "the main one" and whatever a host calls it are host vocabulary, and a
/// framework that shipped one of those names would be picking a side.
///
/// ## Why the rest are optional
///
/// ``email`` and ``plan`` mean "the tool could not say", which is distinct from
/// there being no account: an API-key login is a real account with no user
/// attached, and reporting it as absent would hide an account that works.
public protocol Account: Sendable {
    var id: AccountID { get }
    var name: String { get }
    var email: String? { get }
    var plan: String? { get }
    var workspace: String? { get }
}

extension Account {
    public var email: String? { nil }
    public var plan: String? { nil }
    public var workspace: String? { nil }
}

/// An account's fields, in the shape they take on the wire.
///
/// The concrete `Codable` type ``Account`` deliberately is not: a protocol cannot
/// be `Decodable`, because decoding has to know what to build. Serialization
/// belongs here so the interface stays clean enough for a proxy to conform to it,
/// and so a host that decoded a reply has something to hand back as an `Account`.
public struct AccountRecord: Account, Codable, Equatable {
    public let id: AccountID
    public let name: String
    public let email: String?
    public let plan: String?
    public let workspace: String?

    public init(
        id: AccountID,
        name: String,
        email: String? = nil,
        plan: String? = nil,
        workspace: String? = nil
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.plan = plan
        self.workspace = workspace
    }

    public init(_ account: any Account) {
        self.init(id: account.id, name: account.name, email: account.email,
                  plan: account.plan, workspace: account.workspace)
    }
}

/// What can go wrong with an account operation, in terms both sides share.
///
/// These are the cases a host has to tell apart to say anything useful to a
/// person. Anything else a plugin hits is its own business and reaches the host
/// as a plain failure.
public enum AccountError: Error, Sendable, Equatable {
    /// No account with this id. Distinct from an empty pool: the host asked
    /// about something specific and it is not there.
    case noSuchAccount(AccountID)

    /// An account with this id already exists. The host chose the id, so this is
    /// the host's mistake to hear about rather than something to paper over by
    /// returning the existing one.
    case alreadyExists(AccountID)
}

/// A tool that owns its accounts.
///
/// The host decides *which* account and *when*; the plugin owns everything
/// behind that: where accounts live, what a directory contains, how credentials
/// are stored, and which account is current. The host keeps no second copy to
/// reconcile against, which is what stops the two drifting.
///
/// Every method is `async` because a plugin is usually another process, so every
/// call is a round trip. A synchronous requirement would leave a remote
/// conformer blocking a thread on a pipe, or unable to conform at all.
public protocol AIToolAccounts: AITool {

    /// Every account this tool holds.
    ///
    /// - Returns: empty when there are none. A fresh install has no accounts and
    ///   that is not a failure.
    func list() async throws -> [any Account]

    /// The account designated as current.
    ///
    /// - Returns: `nil` when nothing is designated yet — the state a fresh
    ///   install is in, and not worth making every caller handle as an error.
    func current() async throws -> (any Account)?

    /// Designate an account as the current one.
    ///
    /// The host decides: it knows this shell and what the person just asked for.
    /// The plugin persists the decision and answers ``current()`` with it.
    ///
    /// - Throws: ``AccountError/noSuchAccount(_:)`` when there is no such
    ///   account. Designating something that does not exist would make the next
    ///   ``current()`` either lie or fail, and the failure is better here, where
    ///   the caller still knows what it asked for.
    func setCurrent(id: AccountID) async throws

    /// Create an account under an id and name the host chose.
    ///
    /// Everything the account needs to exist is the plugin's to create —
    /// directories, credential storage, whatever links the tool wants — and the
    /// host neither prepares nor inspects any of it.
    ///
    /// - Returns: the account as stored, so the host reads back what actually
    ///   exists rather than assuming its request was honoured verbatim.
    /// - Throws: ``AccountError/alreadyExists(_:)`` when the id is taken.
    func addAccount(id: AccountID, name: String) async throws -> any Account

    /// Pin an account to a workspace.
    ///
    /// Separate from ``setCurrent(id:)`` because they answer different questions.
    /// Current is *which account is designated right now* — one answer, whatever
    /// else is true. A pin is *where this account belongs*, and it stays put when
    /// the current one changes. Folding the two together would make one of them
    /// unanswerable: scoping current by workspace leaves "which account is
    /// current" with no answer until you also say where, and the host asks that
    /// plain question.
    ///
    /// The workspace is an opaque string. The plugin records it and never has to
    /// know what a workspace is, the same way it takes a directory path without
    /// knowing what the host keeps in it.
    ///
    /// - Throws: ``AccountError/noSuchAccount(_:)`` when there is no such
    ///   account, so a pin that recorded nothing is never reported as done.
    func pin(id: AccountID, to workspace: String) async throws

    /// Remove an account and everything the plugin keeps for it.
    ///
    /// If the deleted account was current, the plugin clears that: leaving
    /// ``current()`` outside ``list()`` would have a host render a row for
    /// something that is gone.
    ///
    /// - Throws: ``AccountError/noSuchAccount(_:)`` when there is no such
    ///   account, so a delete that removed nothing is never reported as done.
    func deleteAccount(id: AccountID) async throws
}
