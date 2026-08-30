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

    /// The raw descriptors, captured once at init.
    ///
    /// The read path uses `poll`/`read` directly, so `FileHandle` adds nothing
    /// but a way to crash: asking a closed handle for its `fileDescriptor`
    /// raises an Objective-C exception that Swift cannot catch. Holding the
    /// numbers means `terminate()` can close them without leaving a live reader
    /// holding a handle that will abort the process when touched.
    private let readFD: Int32

    /// Set by `terminate()`. Read before touching a descriptor, since after
    /// termination those numbers are closed and may since have been reused by
    /// something else entirely.
    private var isTerminated = false

    public init(executable: URL, arguments: [String], environment: [String: String]) {
        readFD = outPipe.fileHandleForReading.fileDescriptor
        // Non-blocking once, at construction. `poll` decides when data is
        // there; the flag only stops `read` itself from blocking if it races
        // the poll.
        let flags = fcntl(readFD, F_GETFL)
        if flags != -1 { _ = fcntl(readFD, F_SETFL, flags | O_NONBLOCK) }
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
        // Same reason `receiveLine` checks: once terminated the handle is
        // backed by a closed descriptor, and touching it raises rather than
        // throws.
        guard !isTerminated else { throw TransportError.noPendingReply }

        try inPipe.fileHandleForWriting.write(contentsOf: line)
        try inPipe.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
    }

    public func receiveLine() async throws -> Data? {
        // A terminated transport reports the peer as gone, which is what the
        // protocol says nil means. Reaching the descriptor instead would be a
        // crash, not an error: `FileHandle.fileDescriptor` raises an
        // Objective-C exception once the handle is closed, and nothing in Swift
        // can catch that. The same shape as the `write(_:)` hazard this file
        // already documents — closing the read side simply moved it to the
        // other end of the pipe.
        if isTerminated { return nil }

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
            let chunk = try await readChunk()
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
    /// and termination can be observed. Short enough that either unwinds
    /// promptly, long enough that an idle transport is not spinning.
    private static let pollSliceMilliseconds: Int32 = 50

    /// Reads one chunk, giving up promptly when the task is cancelled or the
    /// transport is terminated.
    ///
    /// A plain blocking `read(2)` cannot be interrupted by task cancellation —
    /// only closing or killing the peer ends it. That put the whole design
    /// upside down: a timeout could not actually stop a read, so callers had to
    /// arrange for something *else* to kill the plugin, and the caller that did
    /// so then killed healthy plugins too. The fix is not a better killer. It
    /// is to stop issuing a syscall that nothing can take back.
    ///
    /// **Actor-isolated on purpose, and that is what makes closing safe.** An
    /// earlier version was `static` and took a raw descriptor, which let the
    /// loop keep polling a number after `terminate()` had closed it — and file
    /// descriptors are reused, so the next slice could poll and consume an
    /// unrelated pipe that had since been handed the same number. Nothing
    /// crashes; the reader just quietly reads someone else's data, and if that
    /// data happens to parse it is accepted as a plugin's reply.
    ///
    /// Isolation removes the race rather than narrowing it. `poll` runs while
    /// the actor is held, so `terminate()` cannot interleave with a syscall on
    /// the descriptor; the suspension between slices is the only place it can
    /// run, and by then this loop is about to re-check `isTerminated` and stop
    /// touching the descriptor for good.
    private func readChunk() async throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 65_536)

        while true {
            try Task.checkCancellation()
            // Re-checked every slice, not only on entry. Entry-only was the
            // hole: a read already inside the loop never learned the transport
            // had gone away.
            if isTerminated { return Data() }

            var descriptor = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Self.pollSliceMilliseconds)

            if ready < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if ready > 0 {
                // POLLNVAL means the descriptor is not open — treat it as the
                // peer being gone rather than reading it and surfacing EBADF.
                if descriptor.revents & Int16(POLLNVAL) != 0 { return Data() }

                let n = buffer.withUnsafeMutableBytes { raw in
                    read(readFD, raw.baseAddress, raw.count)
                }
                if n < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                    if errno == EBADF { return Data() }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                // n == 0 is EOF, and an empty Data is how the caller reads that.
                return Data(buffer[0..<n])
            }

            // Nothing yet. Suspending here is what lets `terminate()` run, and
            // is also the point at which cancellation becomes observable.
            await Task.yield()
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
    /// Idempotent, and safe to call while a `receiveLine` is in flight.
    ///
    /// The waits are `await Task.sleep`, not `usleep`. A synchronous sleep here
    /// would hold the actor for its whole duration — blocking every other call
    /// on this transport, `receiveLine` included — and would also park a thread
    /// of the cooperative pool, which is a scarce resource shared with every
    /// other task in the process.
    public func terminate() async {
        guard !isTerminated else { return }
        isTerminated = true

        if started && process.isRunning {
            process.terminate()

            // Ask first. A well-behaved plugin exits on SIGTERM.
            if await !waitForExit(within: .milliseconds(500)) {
                kill(process.processIdentifier, SIGKILL)
                // SIGKILL cannot be declined, but it is still asynchronous:
                // `kill(2)` returns once the signal is posted, not once the
                // process is gone. Waiting here is what lets a caller treat
                // this returning as "the child is finished" — the previous
                // version returned immediately and left that untrue.
                _ = await waitForExit(within: .milliseconds(500))
            }
        }

        // `close(2)` on the raw numbers rather than `FileHandle.close()`: the
        // handles stay untouched, so any code still holding one cannot trip the
        // uncatchable exception that reading a closed handle raises.
        // Closed through the `FileHandle`s, not with `close(2)` on the raw
        // numbers.
        //
        // `Pipe` hands out handles created with `closeOnDealloc: true`, so they
        // close their remembered descriptor when they are released. Closing the
        // number directly leaves that intact: the descriptor is freed, the OS
        // hands the number to whatever opens next, and then the handle's deinit
        // closes it a second time — shutting an unrelated file or socket
        // belonging to some other part of the program. Two owners of one
        // descriptor with no coordination between them; `FileHandle.close()`
        // marks the handle closed so its deinit does nothing.
        //
        // The reason this can be done safely at all is that `readChunk` is
        // actor-isolated: no read is inside a syscall on these descriptors
        // while this runs.
        try? inPipe.fileHandleForWriting.close()
        try? outPipe.fileHandleForReading.close()
    }

    /// Polls for the child's exit in short async slices. Returns whether it
    /// actually exited before the deadline.
    private func waitForExit(within duration: Duration) async -> Bool {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {
            if !process.isRunning { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !process.isRunning
    }
}
