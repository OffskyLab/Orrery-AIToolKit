import Foundation
import Dispatch
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

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
            let chunk = try await Self.interruptibleRead(fd: fd)
            if chunk.isEmpty {
                if pending.isEmpty { return nil }
                let leftover = pending
                pending.removeAll()
                return leftover
            }
            pending.append(chunk)
        }
    }

    /// How long each `poll` waits before handing control back so cancellation
    /// can be observed. Short enough that a cancelled call unwinds promptly,
    /// long enough that an idle transport is not spinning.
    private static let pollSliceMilliseconds: Int32 = 50

    /// Reads one chunk from `fd`, giving up promptly when the task is
    /// cancelled.
    ///
    /// A plain blocking `read(2)` cannot be interrupted by task cancellation —
    /// only closing or killing the peer ends it. That put the whole design
    /// upside down: a timeout could not actually stop a read, so callers had to
    /// arrange for something *else* to kill the plugin, and the caller that did
    /// so then killed healthy plugins too. The fix is not a better killer. It
    /// is to stop issuing a syscall that nothing can take back.
    ///
    /// So the descriptor is non-blocking and `poll` waits in short slices.
    /// Between slices the task's cancellation state is observable, which makes
    /// the read cooperatively cancellable and lets an ordinary timeout do its
    /// job. It also removes the need for the peer to cooperate at all: a plugin
    /// that ignores SIGTERM, or that leaves a grandchild holding the pipe, no
    /// longer wedges the host — the host simply stops waiting.
    private static func interruptibleRead(fd: Int32) async throws -> Data {
        // Set once per call rather than at spawn: the flag belongs to the open
        // file description, and leaving the descriptor blocking for anyone else
        // who might inherit it is the safer default.
        let flags = fcntl(fd, F_GETFL)
        if flags != -1 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

        var buffer = [UInt8](repeating: 0, count: 65_536)

        while true {
            try Task.checkCancellation()

            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, pollSliceMilliseconds)

            if ready < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if ready == 0 {
                // Nothing yet. Yield so a cancelled task is not starved by a
                // peer that never speaks.
                await Task.yield()
                continue
            }

            let n = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, raw.count)
            }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            // n == 0 is EOF, and an empty Data is how the caller reads that.
            return Data(buffer[0..<n])
        }
    }

    /// Ends the child process and releases this side of the pipes.
    ///
    /// No longer load-bearing for unblocking a read — `interruptibleRead` gives
    /// up on its own — so this is purely about not leaving a process behind.
    ///
    /// SIGTERM is asked first and SIGKILL follows if the child is still there,
    /// because a plugin may trap or ignore the polite one. The old
    /// `if process.isRunning` guard is gone: when the child has already exited
    /// but something it spawned still holds the pipe, that guard skipped the
    /// descriptor cleanup as well, which was the one part still worth doing.
    ///
    /// A plugin that leaves a grandchild holding stdout is violating the
    /// process contract in the README, and the orphan outlives this call. That
    /// is the plugin's defect; the host's obligation is only to keep working,
    /// which it now does.
    public func terminate() {
        if process.isRunning {
            process.terminate()
            // Brief grace period, then insist.
            let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < deadline {
                usleep(10_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        try? inPipe.fileHandleForWriting.close()
        try? outPipe.fileHandleForReading.close()
    }
}
