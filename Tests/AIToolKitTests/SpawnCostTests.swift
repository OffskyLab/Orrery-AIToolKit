import Foundation
import Testing
@testable import AIToolKit

/// A plain class purely so `Bundle(for:)` has something to resolve. See the
/// identical marker in `StdioTransportTests.swift`: `Bundle.main` resolves
/// to `swiftpm-testing-helper`'s toolchain location under `swift test`, not
/// to the package's build products directory, so it cannot find the built
/// `AIToolKitTestPlugin` binary. `Bundle(for: Marker.self)` resolves to the
/// `.xctest` bundle this test target was actually loaded from, whose parent
/// directory is the build products directory the plugin binary lands in.
private final class SpawnCostMarker {}

/// Not a pass/fail test — a measurement that prints. The transport decision
/// depends on a number, and a number nobody recorded is a number nobody has.
@Suite("SpawnCost")
struct SpawnCostTests {

    private static var pluginURL: URL {
        Bundle(for: SpawnCostMarker.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("AIToolKitTestPlugin")
    }

    @Test("measure spawn plus initialize plus describe")
    func measureRoundTrip() async throws {
        let plugin = Self.pluginURL
        var samples: [Duration] = []

        for _ in 0..<20 {
            let start = ContinuousClock.now
            let t = StdioTransport(
                executable: plugin, arguments: [],
                environment: ["AITOOLKIT_TEST_BEHAVIOUR": "ok"])
            let conn = JSONRPCConnection(transport: t, timeout: .seconds(5))
            _ = try await conn.call("initialize", nil)
            _ = try await conn.call("tool/describe", nil)
            samples.append(ContinuousClock.now - start)
            await t.terminate()
        }

        let sorted = samples.sorted()
        print("SPAWN+INIT+DESCRIBE  median=\(sorted[10])  min=\(sorted[0])  max=\(sorted[19])")
    }
}
