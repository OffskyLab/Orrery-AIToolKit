import Foundation
import Testing
@testable import AIToolKit

@Suite("SpawnCost")
struct SpawnCostTests {

    @Test("measure spawn plus initialize plus describe")
    func measureRoundTrip() async throws {
        let plugin = try TestPluginLocator.url()
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
