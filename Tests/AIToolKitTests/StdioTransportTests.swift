import Foundation
import Testing
@testable import AIToolKit

/// A plain class purely so `Bundle(for:)` has something to resolve. Structs
/// cannot be handed to `Bundle(for:)`.
///
/// `Bundle.main` is not a reliable way to find the built test-plugin binary
/// here: `swift test` on macOS runs swift-testing suites out of process
/// through `swiftpm-testing-helper`, so `Bundle.main` resolves to that
/// helper's location inside the toolchain, not to the package's build
/// products directory. `Bundle(for: Marker.self).bundleURL`, by contrast,
/// resolves to the `.xctest` bundle this test target was actually loaded
/// from — verified empirically, since this is the one place the brief's
/// assumption could not just be trusted. Its parent directory is the build
/// products directory (`.build/.../Products/Debug`), which is exactly where
/// `AIToolKitTestPlugin` lands alongside it.
private final class Marker {}

@Suite("StdioTransport")
struct StdioTransportTests {

    /// The test plugin binary, beside the test bundle in the build directory.
    private static var pluginURL: URL {
        Bundle(for: Marker.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("AIToolKitTestPlugin")
    }

    private func makeTransport(behaviour: String) -> StdioTransport {
        StdioTransport(
            executable: Self.pluginURL,
            arguments: [],
            environment: ["AITOOLKIT_TEST_BEHAVIOUR": behaviour])
    }

    @Test("a real child process answers tool/describe over a real pipe")
    func realPipeWorks() async throws {
        let transport = makeTransport(behaviour: "ok")
        let conn = JSONRPCConnection(transport: transport, timeout: .seconds(5))
        let result = try await conn.call("tool/describe", nil)
        guard case .object(let obj) = result else {
            Issue.record("expected an object result"); return
        }
        #expect(obj["id"] == .string("testtool"))
    }

    @Test("a stray debug line on stdout is skipped, not fatal")
    func noisyPluginStillWorks() async throws {
        let transport = makeTransport(behaviour: "noisy")
        let conn = JSONRPCConnection(transport: transport, timeout: .seconds(5))
        let result = try await conn.call("tool/describe", nil)
        guard case .object(let obj) = result else {
            Issue.record("expected an object result"); return
        }
        #expect(obj["id"] == .string("testtool"))
    }

    @Test("a plugin that never answers trips the timeout instead of hanging the host")
    func hangingPluginTimesOut() async throws {
        let transport = makeTransport(behaviour: "hang")
        let conn = JSONRPCConnection(transport: transport, timeout: .milliseconds(300))
        // `JSONRPCConnection.call` uses a task group internally, and a task
        // group cannot return until every child task it started — including
        // the one blocked reading the hung child's reply — has actually
        // finished, not merely been asked to cancel. Task cancellation
        // cannot interrupt that blocking read; only killing the process
        // does. So `conn.call` itself will not produce its timeout error
        // until something kills the process concurrently with this call —
        // calling `terminate()` only after `#expect` returns would never
        // run, because `#expect` would never return.
        let killer = Task {
            try? await Task.sleep(for: .milliseconds(600))
            await transport.terminate()
        }
        await #expect(throws: JSONRPCError.timedOut(method: "tool/describe")) {
            try await conn.call("tool/describe", nil)
        }
        await killer.value
    }
}
