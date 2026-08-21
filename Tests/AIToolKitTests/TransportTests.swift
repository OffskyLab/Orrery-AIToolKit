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
        // Verify the transport remains closed: a second call also returns nil
        let got2 = try await t.receiveLine()
        #expect(got2 == nil)
    }

    @Test("receiveLine before any send throws noPendingReply")
    func noPendingReplyOnEmptyQueue() async throws {
        let t = InMemoryTransport { _ in Data("reply".utf8) }
        do {
            _ = try await t.receiveLine()
            #expect(Bool(false), "expected noPendingReply")
        } catch TransportError.noPendingReply {
            // Expected
        }
    }

    @Test("concurrent sends maintain request order despite handler speeds")
    func concurrentSendsPreserveOrder() async throws {
        let t = InMemoryTransport { line in
            let text = String(decoding: line, as: UTF8.self)
            // First request: slow handler
            if text == "slow" {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                } catch { }
                return Data("slow-reply".utf8)
            }
            // Second request: fast handler
            return Data("fast-reply".utf8)
        }

        // Issue both sends concurrently
        async let send1 = t.send(Data("slow".utf8))
        async let send2 = t.send(Data("fast".utf8))
        _ = try await (send1, send2)

        // Verify we get replies in request order, not completion order
        let reply1 = try await t.receiveLine()
        #expect(String(decoding: reply1! as Data, as: UTF8.self) == "slow-reply")

        let reply2 = try await t.receiveLine()
        #expect(String(decoding: reply2! as Data, as: UTF8.self) == "fast-reply")
    }
}
