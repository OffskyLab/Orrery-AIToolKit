# AIToolKit

Describes an AI CLI tool — how to launch it, where its config lives, how it
logs in — so a host application can manage several of them without knowing
any of them by name.

Built for [orrery](https://github.com/OffskyLab/Orrery), but deliberately
independent of it: a tool plugin depends on this package alone, never on
orrery itself.

**Status: 0.x.** The interface is expected to change while orrery's own
migration onto it is in progress. Semver applies from 1.0.

## Conforming a tool

`AITool` is a protocol. A conformer answers `id` and `displayName`; everything
else has a default.

```swift
struct CodexTool: AITool {
    let id = "codex"
    let displayName = "Codex CLI"
}
// configDirectoryName == ".codex", configDirEnvVar == nil, installCommand == nil, …

try AIToolRegistry.shared.register(CodexTool())
```

`register` throws when the id is empty, carries whitespace or a newline,
contains a path separator or a control character, or begins with `.`. Each
rejection names the rule it broke, as a `RegistrationError.Reason`.

The id is the one part of a description that leaves the process, and it leaves
in two shapes. It is **written into line-based records**: an id of
`"cursor\nclaude"` read back as two lines is how a host silently marks a
*different* tool's one-shot work complete, and a trailing space is written
verbatim and read back trimmed, so it never matches itself. And it is
**path-forming**, because `configDirectoryName` defaults to `".\(id)"` — so
`"a/b"` becomes a nested path where one segment was expected, `"./../evil"`
becomes `"../../evil"` and escapes the home directory it was joined onto, and a
NUL truncates the path at the first POSIX call. The package ships the default
that makes ids path-forming, so the package validates them, rather than leaving
every host to rediscover the rule.

`Sendable` is the only conformance `AITool` refines. `Codable`, `Hashable` and
`Equatable` are deliberately absent: nothing here serializes to a wire format,
and decoding would need a concrete type anyway — recovering one from a stored
id needs an id→type table, which is what `AIToolRegistry` is. A host encodes
the `id` and reads it back with `registry.tool(id:)`.

## Concurrency

Strict Swift 6, no escape hatches: no `@unchecked Sendable`,
`nonisolated(unsafe)` or `@preconcurrency` anywhere. `AIToolRegistry` is plain
`Sendable`, holding its table in a `Mutex` so the compiler verifies the claim
instead of taking the package's word for it. The manifest states
`swiftLanguageModes: [.v6]` rather than inheriting it.

## What belongs here

Facts about a tool. `~/.claude` is where Claude Code keeps its config;
gemini-cli ignores `GEMINI_CONFIG_DIR` and reads only `$HOME/.gemini`.

## What does not

Anything the *host* decides. Account pools, credential storage policy,
directory sharing — those live in the host, because they are its inventions,
not the tool's.
