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

        /// Which rule the id broke.
        ///
        /// Distinct cases rather than one `malformed`: a third party whose
        /// registration was refused has to be able to learn *which* rule they
        /// broke without reading this package's source.
        public enum Reason: Equatable, Sendable {

            /// The id is `""`. It names nothing, and every empty id is the
            /// same key.
            case empty

            /// The id contains whitespace or a newline. A newline splits one
            /// id into two records in a line-based file; a space is written
            /// verbatim and read back trimmed.
            case containsWhitespaceOrNewline

            /// The id contains a path separator. Ids are path-forming —
            /// ``AITool/configDirectoryName`` defaults to `".\(id)"` — so a
            /// separator turns one directory segment into several, and a host
            /// joining the result onto a home directory can be walked out of
            /// it.
            case containsPathSeparator

            /// The id begins with `.`, which includes the ids `"."` and `".."`
            /// themselves. The leading dot is what `configDirectoryName` adds;
            /// an id supplying its own yields `"..name"`, and `".."` yields
            /// `"..."`-style nonsense at best and traversal at worst.
            case beginsWithDot

            /// The id contains a control character, NUL included. POSIX APIs
            /// truncate a path at NUL, so the directory a host creates is not
            /// the one the id described.
            case containsControlCharacter
        }
    }

    /// The registry a host application registers into at startup.
    public static let shared = AIToolRegistry()

    private let storage = Mutex<[String: any AITool]>([:])

    public init() {}

    /// Characters that divide one path segment from the next. `\` is listed
    /// alongside `/` because it separates on Windows, and an id is validated
    /// once but may be carried to a host built elsewhere.
    private static let pathSeparators: Set<Character> = ["/", "\\"]

    /// Registers `tool`, replacing any existing description with the same id.
    ///
    /// Throws ``RegistrationError`` when the id is empty, carries whitespace or
    /// a newline, contains a path separator or a control character, or begins
    /// with `.` — see ``AITool/id`` for why none of those can be stored, and
    /// ``RegistrationError/Reason`` for which rule a given rejection names.
    ///
    /// A rejected registration leaves the registry exactly as it was; there is
    /// no partial state to unwind, because validation happens before the lock
    /// is taken. Keeping it outside `withLock` is deliberate on two counts:
    /// nothing here needs the table to decide, and throwing out of a critical
    /// section is a habit worth not forming.
    ///
    /// The order of the checks is load-bearing in one place: whitespace is
    /// tested before control characters, because tab, newline and carriage
    /// return are both, and the whitespace reason is the more informative of
    /// the two for the ids hosts actually get handed.
    public func register(_ tool: any AITool) throws {
        let id = tool.id
        guard !id.isEmpty else {
            throw RegistrationError.invalidID(id, reason: .empty)
        }
        guard id.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) })
        else {
            throw RegistrationError.invalidID(id, reason: .containsWhitespaceOrNewline)
        }
        guard !id.contains(where: { Self.pathSeparators.contains($0) }) else {
            throw RegistrationError.invalidID(id, reason: .containsPathSeparator)
        }
        guard !id.hasPrefix(".") else {
            throw RegistrationError.invalidID(id, reason: .beginsWithDot)
        }
        guard id.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw RegistrationError.invalidID(id, reason: .containsControlCharacter)
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
