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

        private var accounts: [Account] = []
        private var currentID: AccountID?

        func list() async throws -> [Account] { accounts }

        func current() async throws -> Account? {
            currentID.flatMap { wanted in accounts.first { $0.id == wanted } }
        }

        func setCurrent(id: AccountID) async throws {
            guard accounts.contains(where: { $0.id == id }) else {
                throw AccountError.noSuchAccount(id)
            }
            currentID = id
        }

        func addAccount(id: AccountID, name: String) async throws -> Account {
            guard !accounts.contains(where: { $0.id == id }) else {
                throw AccountError.alreadyExists(id)
            }
            let account = Account(id: id, name: name)
            accounts.append(account)
            return account
        }

        func deleteAccount(id: AccountID) async throws {
            guard let index = accounts.firstIndex(where: { $0.id == id }) else {
                throw AccountError.noSuchAccount(id)
            }
            accounts.remove(at: index)
            if currentID == id { currentID = nil }
        }
    }

    @Test("an account carries what a listing needs and nothing a host invented")
    func accountFields() {
        let account = Account(id: "a1", name: "work", email: "a@example.com", plan: "Max")
        #expect(account.id == "a1")
        #expect(account.name == "work")
        #expect(account.email == "a@example.com")
        #expect(account.plan == "Max")
    }

    @Test("email and plan are optional — a tool that cannot say says so")
    func factsAreOptional() {
        let account = Account(id: "a1", name: "work")
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
        #expect(listed == [returned])
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

    @Test("an account survives a JSON round trip unchanged")
    func codableRoundTrip() throws {
        let account = Account(id: "a1", name: "work", email: "a@example.com", plan: "Max")
        let data = try JSONEncoder().encode(account)
        #expect(try JSONDecoder().decode(Account.self, from: data) == account)
    }
}
