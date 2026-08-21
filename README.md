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

AIToolRegistry.shared.register(CodexTool())
```

`AITool` is deliberately neither `Codable` nor `Hashable`. Decoding needs a
concrete type, and recovering one from a serialized id needs an id→type
table — which is what `AIToolRegistry` is. So a host encodes the `id` and reads
it back with `registry.tool(id:)`.

## What belongs here

Facts about a tool. `~/.claude` is where Claude Code keeps its config;
gemini-cli ignores `GEMINI_CONFIG_DIR` and reads only `$HOME/.gemini`.

## What does not

Anything the *host* decides. Account pools, credential storage policy,
directory sharing — those live in the host, because they are its inventions,
not the tool's.
