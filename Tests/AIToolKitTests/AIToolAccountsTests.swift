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

    /// An account that can act on itself, because it holds the store it lives in.
    ///
    /// This is the shape a real plugin's account takes: the value a caller holds
    /// is a view onto storage, not a detached copy. A type that could not reach
    /// its store would have to answer every one of these by failing.
    private struct PooledAccount: Account {
        let record: AccountRecord
        let pool: Pool

        var id: AccountID { record.id }
        var name: String { record.name }
        var email: String? { record.email }
        var plan: String? { record.plan }
        var workspace: String? { record.workspace }

        func pin(to workspace: String) async throws {
            try await pool.setWorkspace(workspace, for: record.id)
        }

        func makeCurrent() async throws {
            try await pool.designate(record.id)
        }

        func delete() async throws {
            try await pool.remove(record.id)
        }

        func adoptLogin(from directory: URL) async throws {
            try await pool.adopt(directory, for: record.id)
        }
    }

    /// A plugin that keeps its accounts in memory, standing in for one that
    /// keeps them on disk. It exists to prove the protocol is implementable
    /// without a host handing over any storage — which is the whole claim.
    private actor Pool: AIToolAccounts {
        nonisolated let id = "pool"
        nonisolated let displayName = "Pool"

        enum PoolError: Error { case noLoginFound }

        private var records: [AccountRecord]
        private var currentID: AccountID?
        private(set) var adopted: Set<AccountID> = []

        init(accounts: [AccountRecord] = [], current: AccountID? = nil) {
            self.records = accounts
            self.currentID = current
        }

        private func view(_ record: AccountRecord) -> PooledAccount {
            PooledAccount(record: record, pool: self)
        }

        func list() async throws -> [any Account] { records.map(view) }

        func current() async throws -> (any Account)? {
            currentID.flatMap { wanted in records.first { $0.id == wanted } }.map(view)
        }

        func addAccount(id: AccountID, name: String) async throws -> any Account {
            guard !records.contains(where: { $0.id == id }) else {
                throw AccountError.alreadyExists(id)
            }
            let record = AccountRecord(id: id, name: name)
            records.append(record)
            return view(record)
        }

        // MARK: - What an account calls back into

        func setWorkspace(_ workspace: String, for id: AccountID) throws {
            guard let index = records.firstIndex(where: { $0.id == id }) else {
                throw AccountError.noSuchAccount(id)
            }
            let r = records[index]
            records[index] = AccountRecord(id: r.id, name: r.name, email: r.email,
                                           plan: r.plan, workspace: workspace)
        }

        func designate(_ id: AccountID) throws {
            guard records.contains(where: { $0.id == id }) else {
                throw AccountError.noSuchAccount(id)
            }
            currentID = id
        }


        /// Stands in for a tool taking a credential out of a directory. The
        /// marker file is this fixture's "credential": present means a login
        /// happened there, absent means nothing to take.
        func adopt(_ directory: URL, for id: AccountID) throws {
            guard records.contains(where: { $0.id == id }) else {
                throw AccountError.noSuchAccount(id)
            }
            let credential = directory.appendingPathComponent("credential")
            guard FileManager.default.fileExists(atPath: credential.path) else {
                throw PoolError.noLoginFound
            }
            adopted.insert(id)
        }

        func remove(_ id: AccountID) throws {
            guard let index = records.firstIndex(where: { $0.id == id }) else {
                throw AccountError.noSuchAccount(id)
            }
            records.remove(at: index)
            if currentID == id { currentID = nil }
        }
    }

    /// The smallest conformer: two properties and the four operations.
    ///
    /// None of the operations has a default, on purpose. One that did nothing
    /// would be a conformance that lies — a host would be told the work was done
    /// — and one that threw would hide the decision from whoever wrote the type.
    /// The facts still default, which is what keeps this small.
    private struct Minimal: Account {
        let id: AccountID
        let name: String

        func pin(to workspace: String) async throws {}
        func makeCurrent() async throws {}
        func delete() async throws {}
        func adoptLogin(from directory: URL) async throws {}
    }

    @Test("a conformer supplies id, name and the operations; the facts default")
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

    /// Reaching an account and asking it to pin itself — the path a host takes.
    private func account(_ id: AccountID, in pool: Pool) async throws -> any Account {
        try #require(try await pool.list().first { $0.id == id })
    }

    /// A directory a tool has just logged into, and one it has not.
    private func stagingDir(withLogin: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("adopt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if withLogin {
            try Data("token".utf8).write(to: url.appendingPathComponent("credential"))
        }
        return url
    }

    @Test("an account takes the login out of a directory the host hands over")
    func adoptsALogin() async throws {
        let pool = Pool()
        _ = try await pool.addAccount(id: "a1", name: "work")
        let dir = try stagingDir(withLogin: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try await account("a1", in: pool).adoptLogin(from: dir)
        #expect(try await pool.adopted.contains("a1"))
    }

    /// The failure that matters. A login that did not arrive must never be
    /// reported as done — reporting it hands someone an account they believe
    /// works and will not find out about until they try to use it.
    @Test("a directory with no login is an error, not a quiet success")
    func adoptingNothingFails() async throws {
        let pool = Pool()
        _ = try await pool.addAccount(id: "a1", name: "work")
        let dir = try stagingDir(withLogin: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        await #expect(throws: (any Error).self) {
            try await account("a1", in: pool).adoptLogin(from: dir)
        }
        #expect(try await pool.adopted.isEmpty)
    }

    /// The host's directory is a throwaway — it may be gone the moment the call
    /// returns — so a conformer has to take what it needs rather than remember
    /// where it was.
    @Test("the account keeps the login after the directory is gone")
    func adoptedLoginOutlivesTheDirectory() async throws {
        let pool = Pool()
        _ = try await pool.addAccount(id: "a1", name: "work")
        let dir = try stagingDir(withLogin: true)

        try await account("a1", in: pool).adoptLogin(from: dir)
        try FileManager.default.removeItem(at: dir)

        #expect(try await pool.adopted.contains("a1"))
        #expect(try await pool.list().map(\.id) == ["a1"])
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
        try await account("a2", in: pool).makeCurrent()
        #expect(try await pool.current()?.id == "a2")
    }

    /// Designating an account you are not holding is not expressible any more —
    /// `makeCurrent()` is on the account. What must still refuse is the store
    /// beneath the lookup, which is where the id is resolved.
    @Test("designating an account that does not exist is an error, not a silent no-op")
    func setCurrentUnknown() async throws {
        let pool = Pool()
        await #expect(throws: AccountError.self) {
            try await pool.designate("ghost")
        }
        #expect(try await pool.current() == nil)
    }

    @Test("deleting removes it from the listing")
    func deleteRemoves() async throws {
        let pool = Pool()
        _ = try await pool.addAccount(id: "a1", name: "work")
        try await account("a1", in: pool).delete()
        #expect(try await pool.list().isEmpty)
    }

    /// Deleting the pinned account must not leave `current()` pointing at
    /// something the listing no longer contains — a host that trusted the pair
    /// would render a row for an account that is gone.
    @Test("deleting the current account clears current")
    func deleteClearsCurrent() async throws {
        let pool = Pool()
        _ = try await pool.addAccount(id: "a1", name: "work")
        try await account("a1", in: pool).makeCurrent()
        try await account("a1", in: pool).delete()
        #expect(try await pool.current() == nil)
    }

    @Test("deleting something that is not there is an error")
    func deleteUnknown() async throws {
        let pool = Pool()
        await #expect(throws: AccountError.self) {
            try await pool.remove("ghost")
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
        try await account("a1", in: pool).pin(to: "client-x")
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
        try await account("a1", in: pool).pin(to: "origin")
        try await account("a3", in: pool).pin(to: "origin")

        let inOrigin = try await pool.list().filter { $0.workspace == "origin" }
        #expect(inOrigin.map(\.id) == ["a1", "a3"])
    }

    @Test("re-pinning moves the account rather than adding a second home")
    func repinMoves() async throws {
        let pool = Pool()
        _ = try await pool.addAccount(id: "a1", name: "work")
        try await account("a1", in: pool).pin(to: "origin")
        try await account("a1", in: pool).pin(to: "client-x")
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
        try await account("a1", in: pool).makeCurrent()

        try await account("a2", in: pool).pin(to: "origin")
        #expect(try await pool.current()?.id == "a1")

        try await account("a1", in: pool).pin(to: "client-x")
        #expect(try await pool.current()?.id == "a1", "the current account did not move")
        #expect(try await pool.current()?.workspace == "client-x")
    }

    /// Resolving an id to an account is the caller's step now — `pin` lives on the
    /// account, so there is nothing to call for one that does not exist. What must
    /// still refuse is the store beneath it.
    @Test("pinning an account that does not exist is an error")
    func pinUnknown() async throws {
        let pool = Pool()
        await #expect(throws: AccountError.self) {
            try await pool.setWorkspace("origin", for: "ghost")
        }
        #expect(try await pool.list().isEmpty)
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
