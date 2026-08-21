import Foundation
import Testing
@testable import AIToolKit

@Suite("Transport")
struct TransportTests {

    @Test("in-memory transport hands each sent line to the handler and returns its reply")
    func inMemoryRoundTrips() async throws {
        let t = InMemoryTransport { line in
            let text = String(decoding: line, as: UTF8.self)
            return Data("echo:\(text)".utf8)
        }
        try await t.send(Data("hello".utf8))
        let got = try await t.receiveLine()
        #expect(String(decoding: got!, as: UTF8.self) == "echo:hello")
    }

    @Test("a handler returning nil closes the stream")
    func nilHandlerCloses() async throws {
        let t = InMemoryTransport { _ in nil }
        try await t.send(Data("hello".utf8))
        let got = try await t.receiveLine()
        #expect(got == nil)
    }
}
