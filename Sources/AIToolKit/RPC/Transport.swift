import Foundation
import Synchronization

/// One line in, one line out. Everything above this is transport-agnostic,
/// which is what lets a spawned child today become a socket tomorrow without
/// the protocol changing — and, just as usefully, lets almost every test run
/// without spawning anything.
public protocol Transport: Sendable {
    func send(_ line: Data) async throws
    /// The next line, or nil once the peer is gone.
    func receiveLine() async throws -> Data?
}

/// A transport with no process behind it: the handler *is* the peer.
///
/// A handler may take as long as it likes, which is how timeout behaviour is
/// tested without waiting on a real hung process.
public final class InMemoryTransport: Transport {
    public typealias Handler = @Sendable (Data) async -> Data?

    private let handler: Handler
    private let pending = Mutex<[Data?]>([])

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func send(_ line: Data) async throws {
        let reply = await handler(line)
        pending.withLock { $0.append(reply) }
    }

    public func receiveLine() async throws -> Data? {
        pending.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}
