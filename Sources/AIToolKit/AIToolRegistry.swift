import Foundation

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
public final class AIToolRegistry: @unchecked Sendable {

    /// The registry a host application registers into at startup.
    public static let shared = AIToolRegistry()

    private let lock = NSLock()
    private var storage: [String: any AITool] = [:]

    public init() {}

    /// Registers `tool`, replacing any existing description with the same id.
    public func register(_ tool: any AITool) {
        lock.lock()
        defer { lock.unlock() }
        storage[tool.id] = tool
    }

    public func tool(id: String) -> (any AITool)? {
        lock.lock()
        defer { lock.unlock() }
        return storage[id]
    }

    /// Every registered tool, sorted by id.
    ///
    /// Sorted rather than insertion-ordered so iteration is deterministic
    /// however registration happened to be sequenced — several hosts iterate
    /// this to build user-facing output.
    public var all: [any AITool] {
        lock.lock()
        defer { lock.unlock() }
        return storage.values.sorted { $0.id < $1.id }
    }

    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.isEmpty
    }

    /// Empties the registry. Intended for tests.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}
