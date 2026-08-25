import Foundation
import Testing
@testable import AIToolKit

@Suite("StdioTransport")
struct StdioTransportTests {

    /// Throws rather than returning an optional so a layout change surfaces as
    /// a named list of the paths tried — see `TestPluginLocator`.
    private func makeTransport(behaviour: String) throws -> StdioTransport {
        StdioTransport(
            executable: try TestPluginLocator.url(),
            arguments: [],
            environment: ["AITOOLKIT_TEST_BEHAVIOUR": behaviour])
    }

    @Test("a real child process answers tool/describe over a real pipe")
    func realPipeWorks() async throws {
        let transport = try makeTransport(behaviour: "ok")
        let conn = JSONRPCConnection(transport: transport, timeout: .seconds(5))
        let result = try await conn.call("tool/describe", nil)
        guard case .object(let obj) = result else {
            Issue.record("expected an object result"); return
        }
        #expect(obj["id"] == .string("testtool"))
    }

    @Test("a stray debug line on stdout is skipped, not fatal")
    func noisyPluginStillWorks() async throws {
        let transport = try makeTransport(behaviour: "noisy")
        let conn = JSONRPCConnection(transport: transport, timeout: .seconds(5))
        let result = try await conn.call("tool/describe", nil)
        guard case .object(let obj) = result else {
            Issue.record("expected an object result"); return
        }
        #expect(obj["id"] == .string("testtool"))
    }

    @Test("a plugin that never answers trips the timeout instead of hanging the host")
    func hangingPluginTimesOut() async throws {
        let transport = try makeTransport(behaviour: "hang")
        let conn = JSONRPCConnection(transport: transport, timeout: .milliseconds(300))

        // No killer task, and that absence is the assertion.
        //
        // This test used to spawn one, with a comment explaining that a task
        // group cannot return until every child *finishes* and that nothing
        // could finish a blocking `read(2)` except killing the peer. That was
        // an accurate description of a design defect: a timeout that cannot
        // stop the thing it is timing is not a timeout. It also pushed the
        // responsibility outward, and the caller that took it on ended up
        // killing healthy plugins too.
        //
        // The read is now cancellable on its own, so the ordinary timeout is
        // sufficient. If this ever needs a killer again, the read has stopped
        // being interruptible — the test hanging is the signal.
        await #expect(throws: JSONRPCError.timedOut(method: "tool/describe")) {
            try await conn.call("tool/describe", nil)
        }

        await transport.terminate()
    }

    /// `receiveLine`'s contract is that nil means the peer is gone, and a
    /// terminated transport is the clearest case of that. Reaching the
    /// descriptor instead used to abort the host: `FileHandle.fileDescriptor`
    /// raises an Objective-C exception once the handle is closed, and Swift
    /// cannot catch it.
    ///
    /// The same hazard this file already documented for `write(_:)` — closing
    /// the read side to stop leaking descriptors simply moved it to the other
    /// end of the pipe. A fix reintroducing the bug it was modelled on is worth
    /// a test rather than a comment.
    @Test("reading after terminate reports the peer as gone rather than crashing")
    func readAfterTerminateReturnsNil() async throws {
        let transport = try makeTransport(behaviour: "ok")
        let conn = JSONRPCConnection(transport: transport, timeout: .seconds(5))
        _ = try await conn.call("tool/describe", nil)

        await transport.terminate()

        #expect(try await transport.receiveLine() == nil)
        // And it stays that way — a caller polling after close must not get an
        // error where it expects a clean end.
        #expect(try await transport.receiveLine() == nil)
    }

    /// Terminating twice must not double-close a descriptor. The numbers are
    /// reused by the OS, so a second `close(2)` on the same value can shut
    /// something unrelated that has since been handed the same slot.
    @Test("terminating twice is harmless")
    func terminateIsIdempotent() async throws {
        let transport = try makeTransport(behaviour: "ok")
        let conn = JSONRPCConnection(transport: transport, timeout: .seconds(5))
        _ = try await conn.call("tool/describe", nil)

        await transport.terminate()
        await transport.terminate()

        #expect(try await transport.receiveLine() == nil)
    }

    /// The peer that the old design could not survive: it reads the request,
    /// ignores SIGTERM, and never answers. Killing it politely does nothing, so
    /// anything that depended on the peer dying to unblock a read would wait
    /// forever. The host must now give up on its own.
    @Test("a plugin that ignores SIGTERM still cannot hold the host")
    func sigtermIgnoringPluginStillTimesOut() async throws {
        let transport = try makeTransport(behaviour: "hang-ignoring-sigterm")
        let conn = JSONRPCConnection(transport: transport, timeout: .milliseconds(300))

        await #expect(throws: JSONRPCError.timedOut(method: "tool/describe")) {
            try await conn.call("tool/describe", nil)
        }

        // terminate() escalates to SIGKILL, so this returns even though the
        // child refuses the polite signal.
        await transport.terminate()
    }

    @Test("a plugin that dies mid-conversation causes a throw, not a host crash")
    func crashedPluginThrowsRatherThanCrashingHost() async throws {
        let transport = try makeTransport(behaviour: "crash-after-initialize")
        let conn = JSONRPCConnection(transport: transport, timeout: .seconds(5))

        // First call: the plugin answers normally, per the fixture's
        // crash-after-initialize behaviour.
        _ = try await conn.call("tool/describe", nil)

        // Second call: the plugin reads this request and exits without
        // answering. Which side notices the dead plugin first — `send`'s
        // write, if the pipe has already broken, or `receiveLine`'s read,
        // finding EOF — is not pinned here; asserting a specific error would
        // make this brittle. What matters is that the host surfaces this as
        // a thrown Swift error rather than the uncatchable Objective-C
        // exception the non-throwing `FileHandle.write(_:)` would raise on
        // a closed pipe, which nothing in Swift can catch and would take
        // the whole host down over one dead plugin.
        await #expect(throws: (any Error).self) {
            try await conn.call("tool/describe", nil)
        }
    }
}
