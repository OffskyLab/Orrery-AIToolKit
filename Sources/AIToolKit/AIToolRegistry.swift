import Foundation
import Synchronization

/// Which tools exist, according to what has been registered.
///
/// This replaces a host's compile-time list. The difference is not cosmetic:
/// a `CaseIterable` enum is total at compile time, whereas a registry is total
/// only once registration has run. A host must therefore register everything
/// before any code that iterates tools executes — in particular before
/// one-shot migrations, which can otherwise mark themselves complete having
/// silently skipped a tool.
///
/// It is also the id→tool table a host needs to read a serialized `"tool":
/// "claude"` back into something usable: ``AITool`` is a protocol and cannot
/// decode itself, so ``tool(id:)`` is the recovery step.
///
/// ## Thread safety
///
/// A `static let shared` that hosts mutate from anywhere has to be genuinely
/// concurrency-safe, and this one is `Sendable` by the compiler's reckoning
/// rather than by assertion: the only stored property is a `Mutex`, so the
/// checker can see for itself that nothing here is reachable unsynchronized.
/// An `@unchecked Sendable` over a lock would look identical from outside and
/// mean something much weaker — a promise that every future edit remembers to
/// take the lock. There is nothing to remember here, because the dictionary is
/// unreachable except through `withLock`.
public final class AIToolRegistry: Sendable {

    /// Why a tool could not be registered.
    public enum RegistrationError: Error, Equatable, Sendable {

        /// The tool's ``AITool/id`` is not something a host can write down.
        /// Carries the offending id exactly as offered, so a diagnostic can
        /// show it rather than describe it.
        case invalidID(String, reason: Reason)

        public enum Reason: Equatable, Sendable {
            case empty
            case containsWhitespaceOrNewline
        }
    }

    /// The registry a host application registers into at startup.
    public static let shared = AIToolRegistry()

    private let storage = Mutex<[String: any AITool]>([:])

    public init() {}

    /// Registers `tool`, replacing any existing description with the same id.
    ///
    /// Throws ``RegistrationError`` when the id is empty or contains
    /// whitespace or a newline — see ``AITool/id`` for why those cannot be
    /// stored. A rejected registration leaves the registry exactly as it was;
    /// there is no partial state to unwind, because validation happens before
    /// the lock is taken. Keeping it outside `withLock` is deliberate on two
    /// counts: nothing here needs the table to decide, and throwing out of a
    /// critical section is a habit worth not forming.
    public func register(_ tool: any AITool) throws {
        let id = tool.id
        guard !id.isEmpty else {
            throw RegistrationError.invalidID(id, reason: .empty)
        }
        guard id.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) })
        else {
            throw RegistrationError.invalidID(id, reason: .containsWhitespaceOrNewline)
        }

        storage.withLock { $0[id] = tool }
    }

    public func tool(id: String) -> (any AITool)? {
        storage.withLock { $0[id] }
    }

    /// Every registered tool, sorted by id.
    ///
    /// Sorted rather than insertion-ordered so iteration is deterministic
    /// however registration happened to be sequenced — several hosts iterate
    /// this to build user-facing output.
    public var all: [any AITool] {
        storage.withLock { $0.values.sorted { $0.id < $1.id } }
    }

    public var isEmpty: Bool {
        storage.withLock { $0.isEmpty }
    }

    /// Empties the registry. Intended for tests.
    public func reset() {
        storage.withLock { $0.removeAll() }
    }
}
