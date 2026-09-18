import Foundation
import Testing
@testable import AIToolKit

/// The first pair of methods that exist because *two different host features*
/// need an answer, rather than because one capability was factored out.
///
/// They return the same fields today, and that is not an argument for merging
/// them. What differs is the shape of the question: a listing asks about many
/// config directories and wants a cheap answer, while a detail view asks about
/// one and wants the freshest. Which source is authoritative, and what it costs
/// to consult, is the tool's knowledge — so the tool answers each question in
/// its own way instead of the host passing a flag telling it how hard to work.
@Suite("AIToolIdentityReporting")
struct AIToolIdentityReportingTests {

    /// Two sources with different freshness, which is what makes the two methods
    /// distinguishable at all: `cached.json` is written once, `live.json` is what
    /// a fresh read would find.
    private struct TwoSourceTool: AIToolIdentityReporting {
        let id = "twosource"
        let displayName = "Two Source Tool"

        func listIdentities(in configDirs: [URL]) async throws -> [LoginIdentity?] {
            configDirs.map { read($0.appendingPathComponent("cached.json")) }
        }

        func showIdentity(in configDir: URL) async throws -> LoginIdentity? {
            read(configDir.appendingPathComponent("live.json"))
                ?? read(configDir.appendingPathComponent("cached.json"))
        }

        private func read(_ url: URL) -> LoginIdentity? {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8)
            else { return nil }
            let parts = text.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return LoginIdentity(email: String(parts[0]), plan: String(parts[1]))
        }
    }

    private func makeDir(cached: String? = nil, live: String? = nil) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let cached { try Data(cached.utf8).write(to: url.appendingPathComponent("cached.json")) }
        if let live { try Data(live.utf8).write(to: url.appendingPathComponent("live.json")) }
        return url
    }

    @Test("a conforming tool is still an ordinary AITool")
    func refinesAITool() {
        let tool: any AITool = TwoSourceTool()
        #expect(tool.id == "twosource")
        #expect(tool is any AIToolIdentityReporting)
    }

    @Test("a tool that reports no identity simply does not conform")
    func nonConformingToolIsValid() {
        struct Anonymous: AITool {
            let id = "anonymous"
            let displayName = "Anonymous"
        }
        #expect(!((Anonymous() as any AITool) is any AIToolIdentityReporting))
    }

    @Test("listing answers for every directory it was given, in order")
    func listAnswersPositionally() async throws {
        let a = try makeDir(cached: "a@example.com|Pro")
        let b = try makeDir()                                  // never logged in
        let c = try makeDir(cached: "c@example.com|Max")
        defer { for d in [a, b, c] { try? FileManager.default.removeItem(at: d) } }

        let found = try await TwoSourceTool().listIdentities(in: [a, b, c])

        // Positional, not a dictionary: the host asked about three directories
        // and has to be able to line the answers back up with them. A shorter
        // array would silently shift every row after the gap.
        #expect(found.count == 3)
        #expect(found[0]?.email == "a@example.com")
        #expect(found[1] == nil, "a directory with no login is a nil answer, not an omission")
        #expect(found[2]?.plan == "Max")
    }

    @Test("an empty request is an empty answer, not an error")
    func emptyListIsFine() async throws {
        #expect(try await TwoSourceTool().listIdentities(in: []).isEmpty)
    }

    /// The reason the two methods are not one. Same directory, different answer,
    /// because the tool decides what each question is worth.
    @Test("the detail view reaches a fresher source than the listing does")
    func showOutranksList() async throws {
        let dir = try makeDir(cached: "stale@example.com|Free", live: "fresh@example.com|Max")
        defer { try? FileManager.default.removeItem(at: dir) }

        let listed = try await TwoSourceTool().listIdentities(in: [dir])
        let shown = try await TwoSourceTool().showIdentity(in: dir)

        #expect(listed[0]?.email == "stale@example.com")
        #expect(shown?.email == "fresh@example.com")
    }

    @Test("a detail view falls back when the fresher source has nothing")
    func showFallsBack() async throws {
        let dir = try makeDir(cached: "only@example.com|Pro")
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(try await TwoSourceTool().showIdentity(in: dir)?.email == "only@example.com")
    }

    @Test("a directory with no login reports nil rather than empty strings")
    func absentIdentityIsNil() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // nil and LoginIdentity(email: nil, plan: nil) would render the same way,
        // and mean different things: "this tool has no idea" versus "logged in,
        // but it will not say as whom".
        #expect(try await TwoSourceTool().showIdentity(in: dir) == nil)
    }
}
