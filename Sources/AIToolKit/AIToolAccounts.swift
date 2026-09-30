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

    /// Pin this account to a workspace.
    ///
    /// On the account rather than on ``AIToolAccounts`` because it is the
    /// account's own relation: one workspace per account, and the account is what
    /// moves. A `pin(id:to:)` on the tool would make the caller name an account it
    /// is already holding.
    ///
    /// This is also what the protocol was for. An `Account` that only carried
    /// properties could have been a struct; behaviour arriving on it is the case
    /// a struct would have turned into a breaking change.
    ///
    /// The workspace is an opaque string. A conformer records it and never has to
    /// know what a workspace is, the same way it takes a directory path without
    /// knowing what the host keeps in it.
    ///
    /// - Throws: when the pin could not be recorded, so one that changed nothing
    ///   is never reported as done.
    func pin(to workspace: String) async throws

    /// Designate this account as the tool's current one.
    ///
    /// On the account for the same reason as ``pin(to:)``: the caller is holding
    /// the account it means, and a `setCurrent(id:)` on the tool would ask it to
    /// name that account again. Reading which one is current stays on the tool,
    /// because "which account is designated" is a question about the tool and
    /// there may be no answer.
    ///
    /// - Throws: when the designation could not be recorded.
    func makeCurrent() async throws

    /// Take the login sitting in this directory and make it this account's.
    ///
    /// The host runs the tool's login — it knows how to give a subprocess a
    /// terminal, and it took `authLoginCommand` and the config-dir variable off
    /// this tool's own description to do it. What it does not know is what the
    /// tool then wrote, or where an account's credentials belong. So it hands
    /// over the directory the login happened in and stops.
    ///
    /// Everything after that is the tool's: which file holds the credential, or
    /// which entry in a platform keychain, how the entry is named, and what else
    /// travels with it. None of that has ever been expressible as a path, which
    /// is why the host passing one and asking no further is the whole of the
    /// boundary here.
    ///
    /// - Parameter directory: a config directory the tool has just logged into.
    ///   Its lifetime is the host's, and it may be gone the moment this returns,
    ///   so a conformer copies rather than referring to it.
    /// - Throws: when no usable login was found there, or it could not be taken.
    ///   A login that did not arrive must never be reported as done — that is the
    ///   failure that hands someone an account they believe works.
    func adoptLogin(from directory: URL) async throws

    /// Remove this account and everything the tool keeps for it.
    ///
    /// If it was the current one, the conformer clears that: leaving the tool's
    /// current account outside its own listing would have a host render a row for
    /// something that is gone.
    ///
    /// - Throws: when the account could not be removed, so a delete that removed
    ///   nothing is never reported as done.
    func delete() async throws
}

extension Account {
    public var email: String? { nil }
    public var plan: String? { nil }
    public var workspace: String? { nil }
}

/// An account's fields, in the shape they take on the wire.
///
/// The concrete `Codable` type ``Account`` deliberately is not: a protocol cannot
/// be `Decodable`, because decoding has to know what to build.
///
/// It does **not** conform to ``Account``, exactly as ``ToolDescription`` does not
/// conform to ``AITool``. An account can be pinned, and a decoded value has
/// nothing to pin *with* — no store, no connection. A record that conformed would
/// have to answer `pin(to:)` by failing, which is a conformance that lies. The
/// types that conform are the ones that can act: a plugin's own account, and a
/// host-side proxy holding the connection back to it.
public struct AccountRecord: Codable, Sendable, Equatable {
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

    /// A snapshot of any account, for sending or storing.
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
/// ## What is here, and what is on `Account`
///
/// Anything done *to* an account is on ``Account`` — pinning it, designating it,
/// deleting it. A caller doing one of those is already holding the account, and
/// a `verb(id:)` on the tool would ask it to name the thing in its hand.
///
/// What stays here is what only the tool can answer: which accounts exist, which
/// one is designated, and making a new one — the last because there is nothing
/// to call the method on until it is made.
///
/// A consequence worth noticing: "no such account" stops being an operation
/// error. You cannot act on an account you are not holding, so failing to find
/// one is a lookup that failed, earlier and somewhere else.
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

}
