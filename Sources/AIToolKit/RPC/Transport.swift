import Foundation

/// Errors raised by a Transport.
public enum TransportError: Error, Equatable, Sendable {
    /// The queue is empty and the transport is still open.
    case noPendingReply
}

/// One line in, one line out. Everything above this is transport-agnostic,
/// which is what lets a spawned child today become a socket tomorrow without
/// the protocol changing — and, just as usefully, lets almost every test run
/// without spawning anything.
public protocol Transport: Sendable {
    func send(_ line: Data) async throws
    /// The next line from the peer, or nil once the peer has closed the stream.
    func receiveLine() async throws -> Data?
}

/// A transport with no process behind it: the handler *is* the peer.
///
/// A handler may take as long as it likes, which is how timeout behaviour is
/// tested without waiting on a real hung process.
public actor InMemoryTransport: Transport {
    public typealias Handler = @Sendable (Data) async -> Data?

    private let handler: Handler
    private var nextTicket = 0          // claimed before suspending
    private var nextToDeliver = 0       // consumed in strict ticket order
    private var replies: [Int: Data?] = [:]
    private var isClosed = false

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func send(_ line: Data) async throws {
        let ticket = nextTicket          // no await has happened yet
        nextTicket += 1
        let reply = await handler(line)  // other sends may interleave here
        replies[ticket] = reply          // each lands in its own slot
        if reply == nil { isClosed = true }
    }

    public func receiveLine() async throws -> Data? {
        // Drain in ticket order, and drain everything already filled before
        // reporting closed — otherwise a fast close swallows a slower reply
        // that was requested first.
        if let reply = replies.removeValue(forKey: nextToDeliver) {
            nextToDeliver += 1
            return reply
        }
        if isClosed { return nil }
        throw TransportError.noPendingReply
    }
}
