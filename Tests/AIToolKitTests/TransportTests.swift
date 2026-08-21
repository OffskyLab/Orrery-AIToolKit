import Foundation
import Testing
@testable import AIToolKit

/// Lets a test observe that a concurrent handler has actually begun running,
/// rather than merely been scheduled.
///
/// `InMemoryTransport.send` claims its ticket synchronously, before it calls
/// the handler — so the moment a handler starts executing, its `send`'s
/// ticket claim is already in the past. Waiting on this signal before
/// issuing a second `send` therefore pins the ticket order the test needs,
/// without depending on which of two `async let` children the scheduler
/// happens to run first.
private actor StartSignal {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func markStarted() {
        started = true
        continuation?.resume()
        continuation = nil
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

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
        let slowStarted = StartSignal()
        let t = InMemoryTransport { line in
            let text = String(decoding: line, as: UTF8.self)
            // First request: slow handler
            if text == "slow" {
                await slowStarted.markStarted()
                do {
                    try await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                } catch { }
                return Data("slow-reply".utf8)
            }
            // Second request: fast handler
            return Data("fast-reply".utf8)
        }

        // Issue the slow send, then wait for its handler to actually start
        // running before issuing the second. `send` claims its ticket
        // synchronously before calling the handler, so by the time the
        // handler signals it has started, the slow send has already claimed
        // ticket 0 — the second send cannot claim a ticket before it is even
        // issued. Without this, the two `async let` sends race to enter the
        // actor, and which one claims ticket 0 is scheduler-dependent, not
        // request-order-dependent, which is what made this test flake under
        // load.
        async let send1 = t.send(Data("slow".utf8))
        await slowStarted.waitUntilStarted()
        async let send2 = t.send(Data("fast".utf8))
        _ = try await (send1, send2)

        // Verify we get replies in request order, not completion order
        let reply1 = try await t.receiveLine()
        #expect(String(decoding: reply1! as Data, as: UTF8.self) == "slow-reply")

        let reply2 = try await t.receiveLine()
        #expect(String(decoding: reply2! as Data, as: UTF8.self) == "fast-reply")
    }
}
