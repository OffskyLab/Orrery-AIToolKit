import Foundation
import Testing
@testable import AIToolKit

/// The account surface as it crosses the wire.
///
/// Separate from `AIToolAccountsTests`, which pins the contract in Swift terms.
/// What a wire format can quietly get wrong is different: an ordinary empty
/// answer encoded as an error, an optional field dropped instead of sent as
/// null, or a mutation reported as done when the plugin refused it.
@Suite("PluginServer accounts")
struct PluginServerAccountTests {

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

    private struct Silent: AITool {
        let id = "silent"
        let displayName = "Silent"
    }

    private func reply(
        to method: String, params: RPCParams? = nil, tool: any AITool
    ) async throws -> JSONRPCResponse? {
        let req = JSONRPCRequest(id: 1, method: method, params: params)
        guard let out = await PluginServer.handle(line: try JSONEncoder().encode(req), tool: tool)
        else { return nil }
        return try JSONDecoder().decode(JSONRPCResponse.self, from: out)
    }

    private func object(_ res: JSONRPCResponse?) throws -> [String: RPCValue] {
        let response = try #require(res)
        let result = try #require(response.result)
        guard case .object(let obj) = result else {
            Issue.record("expected an object result"); return [:]
        }
        return obj
    }

    @Test("a tool without accounts does not advertise them")
    func capabilitiesFollowConformance() async throws {
        let caps = try object(try await reply(to: "initialize", tool: Silent()))
        guard case .object(let c) = try #require(caps["capabilities"]) else {
            Issue.record("expected capabilities"); return
        }
        #expect(c["tool/list"] == nil)
        #expect(c["tool/addAccount"] == nil)
        #expect(c["tool/pin"] == nil)
        #expect(c["tool/adoptLogin"] == nil)
    }

    @Test("a tool without accounts answers method-not-found, not a silent success")
    func nonConformerRefuses() async throws {
        let res = try #require(try await reply(to: "tool/list", tool: Silent()))
        #expect(res.error?.code == JSONRPCError.methodNotFoundCode)
    }

    @Test("an empty pool is an empty array, not an error")
    func emptyList() async throws {
        let obj = try object(try await reply(to: "tool/list", tool: Pool()))
        #expect(obj["accounts"] == .array([]))
        #expect(try #require(try await reply(to: "tool/list", tool: Pool())).error == nil)
    }

    @Test("nothing pinned is a successful null, not an error")
    func noCurrent() async throws {
        let res = try #require(try await reply(to: "tool/current", tool: Pool()))
        #expect(res.error == nil)
        let obj = try object(res)
        #expect(obj["account"] == .null)
    }

    /// Optional facts travel as explicit nulls. Dropping the keys would make a
    /// host unable to tell "the tool said it does not know" from a reply that
    /// was truncated.
    @Test("an account with no email or plan sends them as null, not as missing keys")
    func optionalsAreExplicitNulls() async throws {
        let pool = Pool(accounts: [AccountRecord(id: "a1", name: "work")])
        let obj = try object(try await reply(to: "tool/list", tool: pool))
        guard case .array(let rows) = try #require(obj["accounts"]),
              case .object(let row) = try #require(rows.first) else {
            Issue.record("expected one account"); return
        }
        #expect(row["email"] == .null)
        #expect(row["plan"] == .null)
        #expect(row["id"] == .string("a1"))
        #expect(row["name"] == .string("work"))
    }

    @Test("every field of a fully-populated account crosses intact")
    func allFieldsCross() async throws {
        let pool = Pool(
            accounts: [AccountRecord(id: "a1", name: "work", email: "a@example.com", plan: "Max")],
            current: "a1")
        let obj = try object(try await reply(to: "tool/current", tool: pool))
        let account = try #require(obj["account"])
        guard case .object(let row) = account else {
            Issue.record("expected an account"); return
        }
        #expect(row["id"] == .string("a1"))
        #expect(row["name"] == .string("work"))
        #expect(row["email"] == .string("a@example.com"))
        #expect(row["plan"] == .string("Max"))
    }

    @Test("adding returns the stored account and takes effect")
    func addAccount() async throws {
        let pool = Pool()
        let obj = try object(try await reply(
            to: "tool/addAccount",
            params: ["id": .string("a1"), "name": .string("work")],
            tool: pool))
        guard case .object(let row) = try #require(obj["account"]) else {
            Issue.record("expected an account"); return
        }
        #expect(row["id"] == .string("a1"))
        #expect(try await pool.list().count == 1)
    }

    @Test("a mutation the plugin refused is an error, never a success")
    func refusedAddIsAnError() async throws {
        let pool = Pool(accounts: [AccountRecord(id: "a1", name: "work")])
        let res = try #require(try await reply(
            to: "tool/addAccount",
            params: ["id": .string("a1"), "name": .string("again")],
            tool: pool))
        #expect(res.error?.code == JSONRPCError.operationFailedCode)
        #expect(try await pool.list().count == 1)
    }

    @Test("pinning an unknown account fails and leaves the pin alone")
    func setCurrentUnknown() async throws {
        let pool = Pool(accounts: [AccountRecord(id: "a1", name: "work")], current: "a1")
        let res = try #require(try await reply(
            to: "tool/setCurrent", params: ["id": .string("ghost")], tool: pool))
        #expect(res.error?.code == JSONRPCError.operationFailedCode)
        #expect(try await pool.current()?.id == "a1")
    }

    @Test("a missing id is invalidParams, distinct from an operation that failed")
    func missingID() async throws {
        for method in ["tool/setCurrent", "tool/addAccount", "tool/deleteAccount"] {
            let res = try #require(try await reply(to: method, tool: Pool()))
            #expect(res.error?.code == JSONRPCError.invalidParamsCode,
                    "\(method) should reject a missing id as invalidParams")
        }
    }

    @Test("adding without a name is invalidParams")
    func missingName() async throws {
        let res = try #require(try await reply(
            to: "tool/addAccount", params: ["id": .string("a1")], tool: Pool()))
        #expect(res.error?.code == JSONRPCError.invalidParamsCode)
    }

    @Test("an unpinned account sends workspace as null, not as a missing key")
    func unpinnedWorkspaceIsNull() async throws {
        let pool = Pool(accounts: [AccountRecord(id: "a1", name: "work")])
        let obj = try object(try await reply(to: "tool/list", tool: pool))
        guard case .array(let rows) = try #require(obj["accounts"]),
              case .object(let row) = try #require(rows.first) else {
            Issue.record("expected one account"); return
        }
        #expect(row["workspace"] == .null)
    }

    @Test("a pin crosses the wire and comes back on the account")
    func pinCrosses() async throws {
        let pool = Pool(accounts: [AccountRecord(id: "a1", name: "work")])
        let res = try #require(try await reply(
            to: "tool/pin",
            params: ["id": .string("a1"), "workspace": .string("client-x")],
            tool: pool))
        #expect(res.error == nil)

        let obj = try object(try await reply(to: "tool/list", tool: pool))
        guard case .array(let rows) = try #require(obj["accounts"]),
              case .object(let row) = try #require(rows.first) else {
            Issue.record("expected one account"); return
        }
        #expect(row["workspace"] == .string("client-x"))
    }

    @Test("pinning without a workspace is invalidParams")
    func pinNeedsAWorkspace() async throws {
        let pool = Pool(accounts: [AccountRecord(id: "a1", name: "work")])
        let res = try #require(try await reply(
            to: "tool/pin", params: ["id": .string("a1")], tool: pool))
        #expect(res.error?.code == JSONRPCError.invalidParamsCode)
    }

    @Test("pinning an unknown account fails and pins nothing")
    func pinUnknownFails() async throws {
        let pool = Pool(accounts: [AccountRecord(id: "a1", name: "work")])
        let res = try #require(try await reply(
            to: "tool/pin",
            params: ["id": .string("ghost"), "workspace": .string("origin")],
            tool: pool))
        #expect(res.error?.code == JSONRPCError.operationFailedCode)
        #expect(try await pool.list().first?.workspace == nil)
    }

    @Test("a directory crosses the wire and the login is taken")
    func adoptLoginCrosses() async throws {
        let pool = Pool(accounts: [AccountRecord(id: "a1", name: "work")])
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adopt-wire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("token".utf8).write(to: dir.appendingPathComponent("credential"))
        defer { try? FileManager.default.removeItem(at: dir) }

        let res = try #require(try await reply(
            to: "tool/adoptLogin",
            params: ["id": .string("a1"), "directory": .string(dir.path)],
            tool: pool))
        #expect(res.error == nil)
        #expect(try await pool.adopted.contains("a1"))
    }

    /// The one that must not come back clean. A host told the login succeeded
    /// goes on to report an account ready to use.
    @Test("a directory with no login comes back as a failure")
    func adoptingNothingIsAnError() async throws {
        let pool = Pool(accounts: [AccountRecord(id: "a1", name: "work")])
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adopt-wire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let res = try #require(try await reply(
            to: "tool/adoptLogin",
            params: ["id": .string("a1"), "directory": .string(dir.path)],
            tool: pool))
        #expect(res.error?.code == JSONRPCError.operationFailedCode)
        #expect(try await pool.adopted.isEmpty)
    }

    @Test("adopting without a directory is invalidParams")
    func adoptNeedsADirectory() async throws {
        let pool = Pool(accounts: [AccountRecord(id: "a1", name: "work")])
        let res = try #require(try await reply(
            to: "tool/adoptLogin", params: ["id": .string("a1")], tool: pool))
        #expect(res.error?.code == JSONRPCError.invalidParamsCode)
    }

    @Test("deleting removes it, and deleting again fails")
    func deleteAccount() async throws {
        let pool = Pool(accounts: [AccountRecord(id: "a1", name: "work")])
        let first = try #require(try await reply(
            to: "tool/deleteAccount", params: ["id": .string("a1")], tool: pool))
        #expect(first.error == nil)
        #expect(try await pool.list().isEmpty)

        let second = try #require(try await reply(
            to: "tool/deleteAccount", params: ["id": .string("a1")], tool: pool))
        #expect(second.error?.code == JSONRPCError.operationFailedCode)
    }
}
