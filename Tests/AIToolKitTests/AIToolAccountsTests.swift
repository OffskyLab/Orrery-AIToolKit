import Foundation
import Testing
@testable import AIToolKit

/// The account surface, from the framework's side.
///
/// What these pin is the contract a host may rely on without knowing which
/// plugin it holds: what `Account` carries, and which answers are ordinary
/// rather than errors. The wire encoding is pinned separately, against
/// `PluginServer`.
@Suite("AIToolAccounts")
struct AIToolAccountsTests {

    /// A plugin that keeps its accounts in memory, standing in for one that
    /// keeps them on disk. It exists to prove the protocol is implementable
    /// without a host handing over any storage — which is the whole claim.
    private actor Pool: AIToolAccounts {
        nonisolated let id = "pool"
        nonisolated let displayName = "Pool"

        private var accounts: [AccountRecord] = []
        private var currentID: AccountID?

        func list() async throws -> [any Account] { accounts }

        func current() async throws -> (any Account)? {
            currentID.flatMap { wanted in accounts.first { $0.id == wanted } }
        }

        func setCurrent(id: AccountID) async throws {
            guard accounts.contains(where: { $0.id == id }) else {
                throw AccountError.noSuchAccount(id)
            }
            currentID = id
        }

        func addAccount(id: AccountID, name: String) async throws -> any Account {
            guard !accounts.contains(where: { $0.id == id }) else {
                throw AccountError.alreadyExists(id)
            }
            let account = AccountRecord(id: id, name: name)
            accounts.append(account)
            return account
        }


        func pin(id: AccountID, to workspace: String) async throws {
            guard let index = accounts.firstIndex(where: { $0.id == id }) else {
                throw AccountError.noSuchAccount(id)
            }
            let a = accounts[index]
            accounts[index] = AccountRecord(id: a.id, name: a.name, email: a.email,
                                      plan: a.plan, workspace: workspace)
        }

        func deleteAccount(id: AccountID) async throws {
            guard let index = accounts.firstIndex(where: { $0.id == id }) else {
                throw AccountError.noSuchAccount(id)
            }
            accounts.remove(at: index)
            if currentID == id { currentID = nil }
        }
    }

    /// The smallest conformer, and the reason `Account` is a protocol at all.
    /// Two properties, everything else defaulted — if this ever needs more, the
    /// defaults extension stopped being real and the protocol stopped paying for
    /// itself.
    private struct Minimal: Account {
        let id: AccountID
        let name: String
    }

    @Test("a conformer supplies two properties; the rest default")
    func minimalConformer() {
        let account: any Account = Minimal(id: "a1", name: "work")
        #expect(account.email == nil)
        #expect(account.plan == nil)
        #expect(account.workspace == nil)
    }

    /// A proxy that has an id and a name and fetches nothing else is a legal
    /// account. That is what a protocol buys over a struct: a forwarding type can
    /// conform without carrying values it does not have.
    @Test("a record can be built from any conformer")
    func recordFromAnyConformer() {
        let record = AccountRecord(Minimal(id: "a1", name: "work"))
        #expect(record == AccountRecord(id: "a1", name: "work"))
    }

    @Test("an account carries what a listing needs and nothing a host invented")
    func accountFields() {
        let account = AccountRecord(id: "a1", name: "work", email: "a@example.com", plan: "Max")
        #expect(account.id == "a1")
        #expect(account.name == "work")
        #expect(account.email == "a@example.com")
        #expect(account.plan == "Max")
    }

    @Test("email and plan are optional — a tool that cannot say says so")
    func factsAreOptional() {
        let account = AccountRecord(id: "a1", name: "work")
        #expect(account.email == nil)
        #expect(account.plan == nil)
    }

    @Test("no accounts yet is an empty list, not an error")
    func emptyPool() async throws {
        let pool = Pool()
        #expect(try await pool.list().isEmpty)
    }

    /// `current()` returns an optional because "nothing pinned yet" is a state a
    /// fresh install is legitimately in. Throwing would make every caller handle
    /// an error for the ordinary case.
    @Test("nothing pinned yet is nil, not an error")
    func noCurrent() async throws {
        let pool = Pool()
        _ = try await pool.addAccount(id: "a1", name: "work")
        #expect(try await pool.current() == nil)
    }

    @Test("adding returns the account the plugin actually stored")
    func addReturnsStored() async throws {
        let pool = Pool()
        let returned = try await pool.addAccount(id: "a1", name: "work")
        let listed = try await pool.list()
        // Compared through the concrete record: `any Account` is not Equatable,
        // which is the cost of the protocol and worth paying for somewhere to put
        // behaviour later.
        #expect(listed.map(AccountRecord.init) == [AccountRecord(returned)])
    }

    @Test("the host names the account; it does not get one back that it did not ask for")
    func hostChoosesIdentity() async throws {
        let pool = Pool()
        let account = try await pool.addAccount(id: "chosen", name: "by the host")
        #expect(account.id == "chosen")
        #expect(account.name == "by the host")
    }

    @Test("setCurrent then current round-trips")
    func setThenGetCurrent() async throws {
        let pool = Pool()
        _ = try await pool.addAccount(id: "a1", name: "work")
        _ = try await pool.addAccount(id: "a2", name: "personal")
        try await pool.setCurrent(id: "a2")
        #expect(try await pool.current()?.id == "a2")
    }

    @Test("pinning an account that does not exist is an error, not a silent no-op")
    func setCurrentUnknown() async throws {
        let pool = Pool()
        await #expect(throws: AccountError.self) {
            try await pool.setCurrent(id: "ghost")
        }
    }

    @Test("deleting removes it from the listing")
    func deleteRemoves() async throws {
        let pool = Pool()
        _ = try await pool.addAccount(id: "a1", name: "work")
        try await pool.deleteAccount(id: "a1")
        #expect(try await pool.list().isEmpty)
    }

    /// Deleting the pinned account must not leave `current()` pointing at
    /// something the listing no longer contains — a host that trusted the pair
    /// would render a row for an account that is gone.
    @Test("deleting the current account clears current")
    func deleteClearsCurrent() async throws {
        let pool = Pool()
        _ = try await pool.addAccount(id: "a1", name: "work")
        try await pool.setCurrent(id: "a1")
        try await pool.deleteAccount(id: "a1")
        #expect(try await pool.current() == nil)
    }

    @Test("deleting something that is not there is an error")
    func deleteUnknown() async throws {
        let pool = Pool()
        await #expect(throws: AccountError.self) {
            try await pool.deleteAccount(id: "ghost")
        }
    }

    @Test("a fresh account is pinned nowhere, and the framework invents no default")
    func unpinnedByDefault() async throws {
        let pool = Pool()
        let account = try await pool.addAccount(id: "a1", name: "work")
        #expect(account.workspace == nil,
                "a default here would be host vocabulary shipped in the framework")
    }

    @Test("pinning is recorded on the account itself")
    func pinIsOnTheAccount() async throws {
        let pool = Pool()
        _ = try await pool.addAccount(id: "a1", name: "work")
        try await pool.pin(id: "a1", to: "client-x")
        #expect(try await pool.list().first?.workspace == "client-x")
    }

    /// The accounts of one workspace are a filter over the listing, not a second
    /// question. One workspace per account is what makes that sound.
    @Test("a host reads a workspace's accounts by filtering the listing")
    func workspaceMembershipIsAFilter() async throws {
        let pool = Pool()
        _ = try await pool.addAccount(id: "a1", name: "one")
        _ = try await pool.addAccount(id: "a2", name: "two")
        _ = try await pool.addAccount(id: "a3", name: "three")
        try await pool.pin(id: "a1", to: "origin")
        try await pool.pin(id: "a3", to: "origin")

        let inOrigin = try await pool.list().filter { $0.workspace == "origin" }
        #expect(inOrigin.map(\.id) == ["a1", "a3"])
    }

    @Test("re-pinning moves the account rather than adding a second home")
    func repinMoves() async throws {
        let pool = Pool()
        _ = try await pool.addAccount(id: "a1", name: "work")
        try await pool.pin(id: "a1", to: "origin")
        try await pool.pin(id: "a1", to: "client-x")
        #expect(try await pool.list().first?.workspace == "client-x")
    }

    /// The two are deliberately independent: current is "which account is
    /// designated right now", a pin is "where this account belongs". Collapsing
    /// them would leave "which account is current" unanswerable until the caller
    /// also said where, and that is the plain question a host asks.
    @Test("pinning does not change which account is current")
    func pinAndCurrentAreIndependent() async throws {
        let pool = Pool()
        _ = try await pool.addAccount(id: "a1", name: "one")
        _ = try await pool.addAccount(id: "a2", name: "two")
        try await pool.setCurrent(id: "a1")

        try await pool.pin(id: "a2", to: "origin")
        #expect(try await pool.current()?.id == "a1")

        try await pool.pin(id: "a1", to: "client-x")
        #expect(try await pool.current()?.id == "a1", "the current account did not move")
        #expect(try await pool.current()?.workspace == "client-x")
    }

    @Test("pinning an account that does not exist is an error")
    func pinUnknown() async throws {
        let pool = Pool()
        await #expect(throws: AccountError.self) {
            try await pool.pin(id: "ghost", to: "origin")
        }
    }

    /// `AccountRecord`, not `Account`: a protocol cannot be `Decodable`, because
    /// decoding has to know what to build. The record is the wire shape.
    @Test("an account record survives a JSON round trip unchanged")
    func codableRoundTrip() throws {
        let account = AccountRecord(id: "a1", name: "work", email: "a@example.com",
                              plan: "Max", workspace: "origin")
        let data = try JSONEncoder().encode(account)
        #expect(try JSONDecoder().decode(AccountRecord.self, from: data) == account)
    }
}
