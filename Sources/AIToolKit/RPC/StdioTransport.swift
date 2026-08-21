import Foundation

/// A transport backed by a spawned child process speaking line-delimited JSON
/// on its stdin and stdout.
///
/// The child's stderr is left attached to the host's, so a plugin's
/// diagnostics reach the operator without polluting the protocol stream.
///
/// Lines that do not parse are skipped by the reader rather than ending the
/// session: a plugin author's stray `print` is a bug in their plugin, not a
/// reason for the host to lose the tool.
///
/// An actor, not a class: `Process` and `Pipe` are not `Sendable`, and the
/// only way to hold them in a `Sendable` conformer without `@unchecked
/// Sendable` is to let actor isolation enforce single-threaded access instead
/// of taking a promise. There is deliberately no `deinit` — an actor's
/// `deinit` cannot touch isolated state, so cleanup is the explicit
/// ``terminate()`` below instead. In production the child exits on its own:
/// when the host process exits, the child's stdin closes and
/// `PluginServer.serve`'s `readLine()` returns nil.
public actor StdioTransport: Transport {
    private let process = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private var started = false
    /// Bytes read but not yet resolved into a complete line. An actor
    /// property, not a local in ``receiveLine()``, because a partial line can
    /// straddle two *calls*, not just two chunks within one call: the
    /// protocol is built to allow pipelining, and a plugin whose reply is
    /// followed by a trailing partial line would otherwise have that
    /// fragment discarded when the local buffer was thrown away at the end
    /// of the call that found the complete line — a loss that presents to
    /// the caller as a timeout rather than as the data-loss bug it is.
    private var pending = Data()

    public init(executable: URL, arguments: [String], environment: [String: String]) {
        process.executableURL = executable
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        process.environment = env
        process.standardInput = inPipe
        process.standardOutput = outPipe
        // stderr deliberately inherited, not captured.
    }

    private func startIfNeeded() throws {
        guard !started else { return }
        started = true
        try process.run()
    }

    public func send(_ line: Data) async throws {
        try startIfNeeded()
        // The throwing variant, not `write(_:)`: on a closed pipe (a plugin
        // that has already died) `write(_:)` raises an Objective-C
        // exception, which Swift cannot catch — it would take the host down
        // over one dead plugin. `write(contentsOf:)` reports the same
        // condition as a thrown Swift error instead, which `send`'s callers
        // already handle.
        try inPipe.fileHandleForWriting.write(contentsOf: line)
        try inPipe.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
    }

    public func receiveLine() async throws -> Data? {
        let fd = outPipe.fileHandleForReading.fileDescriptor
        while true {
            while let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<nl]
                pending.removeSubrange(pending.startIndex...nl)
                // Skip anything that is not a JSON-RPC response: a plugin's
                // stray stdout write must not desynchronise the stream.
                if (try? JSONDecoder().decode(JSONRPCResponse.self, from: Data(line))) != nil {
                    return Data(line)
                }
            }
            let chunk = try await Self.blockingRead(fd: fd)
            if chunk.isEmpty {
                if pending.isEmpty { return nil }
                let leftover = pending
                pending.removeAll()
                return leftover
            }
            pending.append(chunk)
        }
    }

    /// Reads one chunk from `fd` on a background thread rather than on the
    /// actor's own executor.
    ///
    /// `read(2)` blocks for as long as the peer has nothing to say, and
    /// task cancellation cannot interrupt a blocking syscall — only closing
    /// or killing the peer does. Running that blocking call directly inside
    /// an actor-isolated method would additionally wedge every other call on
    /// this actor for the same duration, `terminate()` included: an actor
    /// runs its isolated methods strictly one at a time on its own executor,
    /// so a synchronous block there has no way to yield to a queued
    /// `terminate()` call, and the very call meant to end the block would
    /// never get to run. `nonisolated` — actor type members are nonisolated
    /// by default — and a suspension point at the `await` above is what lets
    /// `terminate()` proceed while this is stuck.
    private static func blockingRead(fd: Int32) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var buffer = [UInt8](repeating: 0, count: 65_536)
                let n = buffer.withUnsafeMutableBytes { raw in
                    read(fd, raw.baseAddress, raw.count)
                }
                if n < 0 {
                    continuation.resume(
                        throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                } else {
                    continuation.resume(returning: Data(buffer[0..<n]))
                }
            }
        }
    }

    /// Ends the child process. Callers that exercise a hanging or otherwise
    /// unresponsive plugin must call this: `receiveLine` blocks on a `read(2)`
    /// that task cancellation cannot interrupt, so a timed-out call leaves
    /// the child running and the read blocked until something kills the
    /// process.
    public func terminate() {
        if process.isRunning { process.terminate() }
    }
}
